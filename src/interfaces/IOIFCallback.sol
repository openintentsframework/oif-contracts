// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice Callback handling for OIF payouts, both outputs and inputs.
 */
interface IOIFCallback {
    /**
     * @notice If configured, is called when the output is filled on the output chain.
     */
    function outputFilled(bytes32 token, uint256 amount, bytes calldata executionData) external;

    /**
     * @notice If configured, is called when the input is sent to the solver.
     * @param inputs Inputs of the order.
     * @param executionData Custom data.
     */
    function orderFinalised(uint256[2][] calldata inputs, bytes calldata executionData) external;
}
