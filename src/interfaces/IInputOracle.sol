// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IInputOracle {
    /**
     * @notice Check if some data has been attested to on the remote chain.
     * @param remoteChainId ChainId of data origin.
     * @param remoteOracle Attestor on the data origin chain.
     * @param application Application that the data originated from.
     * @param dataHash Hash of data.
     */
    function isProven(
        uint256 remoteChainId,
        bytes32 remoteOracle,
        bytes32 application,
        bytes32 dataHash
    ) external view returns (bool);

    /**
     * @notice Check if a series of data has been attested to.
     * @dev More efficient implementation of isProven. Does not return a boolean, instead reverts if false.
     * This function returns true if proofSeries is empty.
     * @param proofSeries remoteChainId, remoteOracle, application, and dataHash encoded in chucks of 32*4=128 bytes.
     */
    function efficientRequireProven(
        bytes calldata proofSeries
    ) external view;
}
