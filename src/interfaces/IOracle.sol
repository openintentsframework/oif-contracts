// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IOracle {
    /**
     * @notice Error thrown when a proof is not valid.
     */
    error NotProven();

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
