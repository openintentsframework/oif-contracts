// SPDX-License-Identifier: Apache-2.0
/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.8.15;

import {L2Configuration} from "../../../libs/RegistryTypes.sol";
import {SecureMerkleTrie} from "@eth-optimism/contracts-bedrock/src/libraries/trie/SecureMerkleTrie.sol";
import {RLPReader} from "@eth-optimism/contracts-bedrock/src/libraries/rlp/RLPReader.sol";
import {ISettledStateProver} from "../../../interfaces/ISettledStateProver.sol";
import {ProverHelpers} from "../../../libs/ProverHelpers.sol";

contract OPStackBedrockProver is ISettledStateProver {
    /**
     * @notice Struct to hold all scalar parameters to _proveWorldStateBedrock
     * @dev To prevent stack-too-deep
     * @param _l2WorldStateRoot L2 state root
     * @param _l2MessagePasserStateRoot L2 message passer state root
     * @param _l2OutputIndex Storage slot index
     * @param _l1WorldStateRoot Proven L1 world state root
     */
    struct BedrockScalarArgs {
        bytes32 _l2WorldStateRoot;
        bytes32 _l2MessagePasserStateRoot;
        uint256 _l2OutputIndex;
        bytes32 _l1WorldStateRoot; // trusted at this point
    }

    /**
     * @notice Invalid output oracle storage root encoding
     */
    error IncorrectOutputOracleStorageRoot(bytes _outputOracleStateRoot);

    /**
     * @notice Block timestamp before finality period
     */
    error BlockBeforeFinalityPeriod(uint256 _blockTimeStamp, uint256 _finalityDelayTimeStamp);

    /**
     * @notice Failed account proof verification
     */
    error InvalidAccountProof(bytes _address, bytes _data, bytes[] _proof, bytes32 _root);

    /**
     * @notice Invalid bedrock settled state proof
     */
    error InvalidBedrockProof(bytes32 _l2WorldStateRoot, bytes32 _l1WorldStateRoot);

    /**
     * @notice Handles Bedrock L2 world state validation
     * @dev Verifies L2 output root against L1 oracle and updates proven state
     * @param _chainConfig L2 configuration values: versionNumber, addresses, storageSlots, finalityDelaySeconds
     * @param _l2WorldStateRoot L2 state root
     * @param _rlpEncodedL2Header RLP encoded block header for that L2 state
     * @param _l1WorldStateRoot Proven L1 world state root
     * @param _proof rest of the proof data: l2MessagePasserStateRoot, l2OutputIndex, l1StorageProof,
     * rlpEncodedOutputOracleData, l1AccountProof
     */
    function proveSettledState(
        L2Configuration memory _chainConfig,
        bytes32 _l2WorldStateRoot,
        bytes memory _rlpEncodedL2Header,
        bytes32 _l1WorldStateRoot,
        bytes calldata _proof
    ) external view returns (bool) {
        (
            bytes32 l2MessagePasserStateRoot,
            uint256 l2OutputIndex,
            bytes[] memory l1StorageProof,
            bytes memory rlpEncodedOutputOracleData,
            bytes[] memory l1AccountProof
        ) = abi.decode(_proof, (bytes32, uint256, bytes[], bytes, bytes[]));

        if (
            !_proveWorldStateBedrock(
                _chainConfig,
                BedrockScalarArgs(_l2WorldStateRoot, l2MessagePasserStateRoot, l2OutputIndex, _l1WorldStateRoot),
                _rlpEncodedL2Header,
                l1StorageProof,
                rlpEncodedOutputOracleData,
                l1AccountProof
            )
        ) {
            revert InvalidBedrockProof(_l2WorldStateRoot, _l1WorldStateRoot);
        }
        return true;
    }

    /**
     * @notice Handles Bedrock L2 world state validation
     * @dev Verifies L2 output root against L1 oracle and updates proven state
     * @param _chainConfig L2 configuration values: versionNumber, addresses, storageSlots, finalityDelaySeconds
     * @param _args Scalar arguments for Bedrock proof
     * @param _rlpEncodedL2Header RLP encoded L2 header
     * @param _l1StorageProof L1 storage proof for L2OutputOracle
     * @param _rlpEncodedOutputOracleData RLP encoded L2OutputOracle data
     * @param _l1AccountProof L1 account proof for L2OutputOracle
     */
    function _proveWorldStateBedrock(
        L2Configuration memory _chainConfig,
        BedrockScalarArgs memory _args,
        bytes memory _rlpEncodedL2Header,
        bytes[] memory _l1StorageProof,
        bytes memory _rlpEncodedOutputOracleData,
        bytes[] memory _l1AccountProof
    ) internal view returns (bool) {
        // Verify block timestamp meets finality delay
        {
            uint256 endBatchBlockTimeStamp =
                _bytesToUint(RLPReader.readBytes(RLPReader.readList(_rlpEncodedL2Header)[11]));

            if (block.timestamp <= endBatchBlockTimeStamp + _chainConfig.finalityDelaySeconds) {
                revert BlockBeforeFinalityPeriod(
                    block.timestamp, endBatchBlockTimeStamp + _chainConfig.finalityDelaySeconds
                );
            }
        }

        bytes32 outputRoot;
        {
            // Generate and verify output root
            bytes32 blockHash = keccak256(_rlpEncodedL2Header);
            outputRoot = _generateOutputRoot(
                _chainConfig.versionNumber, _args._l2WorldStateRoot, _args._l2MessagePasserStateRoot, blockHash
            );
        }

        // Calculate storage slot and verify output root
        // For OPStackBedrock the output root storage slot number is stored in the first storage slot
        bytes32 outputRootStorageSlot =
            bytes32((uint256(keccak256(abi.encode(_chainConfig.storageSlots[0]))) + _args._l2OutputIndex * 2));

        bytes memory outputOracleStateRoot = RLPReader.readBytes(RLPReader.readList(_rlpEncodedOutputOracleData)[2]);

        if (outputOracleStateRoot.length > 32) {
            revert IncorrectOutputOracleStorageRoot(outputOracleStateRoot);
        }

        ProverHelpers.proveStorageBytes32(
            abi.encodePacked(outputRootStorageSlot), outputRoot, _l1StorageProof, bytes32(outputOracleStateRoot)
        );

        // For OPStackBedrock the output oracle address is stored in the first address slot
        _proveAccount(
            abi.encodePacked(_chainConfig.addresses[0]),
            _rlpEncodedOutputOracleData,
            _l1AccountProof,
            _args._l1WorldStateRoot
        );

        return true;
    }

    /**
     * @notice Generates an output root for Bedrock and Cannon proving
     * @param _outputRootVersion Version number (usually 0)
     * @param _worldStateRoot State root
     * @param _messagePasserStateRoot Message passer state root
     * @param _latestBlockHash Latest block hash
     * @return Output root hash
     */
    function _generateOutputRoot(
        uint256 _outputRootVersion,
        bytes32 _worldStateRoot,
        bytes32 _messagePasserStateRoot,
        bytes32 _latestBlockHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_outputRootVersion, _worldStateRoot, _messagePasserStateRoot, _latestBlockHash));
    }

    /**
     * @notice Converts bytes to uint256
     * @dev Manual byte-by-byte conversion
     * @param _b Bytes to convert
     * @return Converted uint256 value
     */
    function _bytesToUint(bytes memory _b) internal pure returns (uint256) {
        uint256 number;
        for (uint256 i = 0; i < _b.length; i++) {
            number = number + uint256(uint8(_b[i])) * (2 ** (8 * (_b.length - (i + 1))));
        }
        return number;
    }

    /**
     * @notice Validates an account proof against a root
     * @dev Uses SecureMerkleTrie for verification
     * @param _address Account address
     * @param _data Expected account data
     * @param _proof Merkle proof
     * @param _root Expected root
     */
    function _proveAccount(bytes memory _address, bytes memory _data, bytes[] memory _proof, bytes32 _root)
        internal
        pure
    {
        if (!SecureMerkleTrie.verifyInclusionProof(_address, _data, _proof, _root)) {
            revert InvalidAccountProof(_address, _data, _proof, _root);
        }
    }
}
