// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice Callback handling for OIF input processing.
 */
interface IInputCallback {
    /**
     * @notice If configured, is called when the input is sent to the solver.
     * @param inputs Inputs of the order.
     * @param executionData Custom data.
     */
    function orderFinalised(uint256[2][] calldata inputs, bytes calldata executionData) external;
}
