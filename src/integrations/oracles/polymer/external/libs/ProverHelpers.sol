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

import {SecureMerkleTrie} from "@eth-optimism/contracts-bedrock/src/libraries/trie/SecureMerkleTrie.sol";
import {RLPWriter} from "@eth-optimism/contracts-bedrock/src/libraries/rlp/RLPWriter.sol";

/**
 * @title ProverHelpers
 * @notice Helper functions for storage and account proofs
 */
library ProverHelpers {
    /**
     * @notice Error thrown when a storage proof is invalid
     */
    error InvalidStorageProof(bytes _key, bytes _val, bytes[] _proof, bytes32 _root);

    /**
     * @notice Validates a bytes32 storage value against a root
     * @dev Encodes value as RLP before verification
     * @param _key Storage slot key
     * @param _val Expected bytes32 value
     * @param _proof Merkle proof
     * @param _root Expected root
     */
    function proveStorageBytes32(bytes memory _key, bytes32 _val, bytes[] memory _proof, bytes32 _root) internal pure {
        // `RLPWriter.writeUint` properly encodes values by removing any leading zeros.
        bytes memory rlpEncodedValue = RLPWriter.writeUint(uint256(_val));
        if (!SecureMerkleTrie.verifyInclusionProof(_key, rlpEncodedValue, _proof, _root)) {
            revert InvalidStorageProof(_key, rlpEncodedValue, _proof, _root);
        }
    }
}
