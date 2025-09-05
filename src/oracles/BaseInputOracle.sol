// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IInputOracle } from "../interfaces/IInputOracle.sol";
import { AssemblyLib } from "../libs/AssemblyLib.sol";

/**
 * @notice Base implementation for storing and exposting attesations for consumers. Maintains a storage slot which is
 * exposed through proving interfaces.
 */
abstract contract BaseInputOracle is IInputOracle {
    error NotDivisible(uint256 value, uint256 divisor);
    error NotProven();

    event OutputProven(uint256 chainid, bytes32 remoteIdentifier, bytes32 application, bytes32 payloadHash);

    /**
     * @notice Stores payload attestations.
     * @dev For gas efficiency, payloads are not stored but instead the hash of the payloads are.
     * To recover a payload, provide the payload (or memory) in calldata then hash it and check.
     */
    mapping(
        uint256 remoteChainId
            => mapping(bytes32 senderIdentifier => mapping(bytes32 application => mapping(bytes32 dataHash => bool)))
    ) internal _attestations;

    //--- Data Attestation Validation ---//

    /**
     * @notice Check if some data has been attested to on some chain.
     * @param remoteChainId ChainId of data origin.
     * @param remoteOracle Attestor on the data origin chain.
     * @param application Application that the data originated from.
     * @param dataHash Hash of data.
     * @return bool Whether the hashed data has been attested to.
     */
    function _isProven(
        uint256 remoteChainId,
        bytes32 remoteOracle,
        bytes32 application,
        bytes32 dataHash
    ) internal view virtual returns (bool) {
        return _attestations[remoteChainId][remoteOracle][application][dataHash];
    }

    /**
     * @notice Check if some data has been attested to on some chain.
     * @param remoteChainId ChainId of data origin.
     * @param remoteOracle Attestor on the data origin chain.
     * @param application Application that the data originated from.
     * @param dataHash Hash of data.
     * @return bool Whether the hashed data has been attested to.
     */
    function isProven(
        uint256 remoteChainId,
        bytes32 remoteOracle,
        bytes32 application,
        bytes32 dataHash
    ) external view returns (bool) {
        return _isProven(remoteChainId, remoteOracle, application, dataHash);
    }

    /**
     * @notice Check if a series of data has been attested to.
     * @dev More efficient implementation of isProven. Does not return a boolean, instead reverts if false.
     * This function returns true if proofSeries is empty.
     * @param proofSeries remoteChainId, remoteOracle, application, and dataHash encoded in chucks of 32*4=128 bytes.
     */
    function efficientRequireProven(
        bytes calldata proofSeries
    ) external view {
        unchecked {
            uint256 proofBytes = proofSeries.length;
            uint256 series = proofBytes / (32 * 4);
            if (series * (32 * 4) != proofBytes) revert NotDivisible(proofBytes, 32 * 4); // unchecked: trivial

            uint256 offset;
            uint256 end;
            assembly ("memory-safe") {
                offset := proofSeries.offset
                // unchecked: proofSeries.offset + proofBytes indicates a point in calldata.
                end := add(proofSeries.offset, proofBytes)
            }
            bool state = true;
            for (; offset < end;) {
                // Load the proof description.
                uint256 remoteChainId;
                bytes32 remoteOracle;
                bytes32 application;
                bytes32 dataHash;
                assembly ("memory-safe") {
                    remoteChainId := calldataload(offset)
                    offset := add(offset, 0x20)
                    remoteOracle := calldataload(offset)
                    offset := add(offset, 0x20)
                    application := calldataload(offset)
                    offset := add(offset, 0x20)
                    dataHash := calldataload(offset)
                    offset := add(offset, 0x20)
                }
                state = AssemblyLib.and(state, _isProven(remoteChainId, remoteOracle, application, dataHash));
            }
            if (!state) revert NotProven();
        }
    }
}
