// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IOracle {
    /**
     * @notice Check if some data has been attested to.
     * @param remoteChainId Chain the data supposedly originated from.
     * @param remoteOracle Identifier for the remote attestation.
     * @param remoteApplication Identifier for the application that the attestation originated from.
     * @param dataHash Hash of data.
     */
    function isProven(
        uint256 remoteChainId,
        bytes32 remoteOracle,
        bytes32 remoteApplication,
        bytes32 dataHash
    ) external view returns (bool);

    /**
     * @notice Check if a series of data has been attested to.
     * @dev More efficient implementation of requireProven. Does not return a boolean, instead reverts if false.
     * This function returns if proofSeries is empty.
     * @param proofSeries remoteOracle, remoteChainId, and dataHash encoded in chucks of 32*4=128 bytes.
     */
    function efficientRequireProven(
        bytes calldata proofSeries
    ) external view;
}
