// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice Callback handling for OIF output processing.
 */
interface IOutputCallback {
    /**
     * @notice If configured, is called when the output is filled on the output chain.
     */
    function outputFilled(
        bytes32 token,
        uint256 amount,
        bytes calldata executionData
    ) external;
}
