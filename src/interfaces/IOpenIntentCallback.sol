// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice Callback handling for OF payouts, both outputs and inputs.
 */
interface IOpenIntentCallback {
    /**
     * @notice If configured, is called when the output is filled on the destination chain.
     */
    function outputFilled(bytes32 token, uint256 amount, bytes calldata executionData) external;

    /**
     * @notice If configured, is called when the input is sent to the filler.
     * @param inputs Inputs of the order.
     * @param executionData Custom data.
     */
    function inputsFilled(uint256[2][] calldata inputs, bytes calldata executionData) external;
}
