// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IOIFCallback } from "../../src/interfaces/IOIFCallback.sol";

contract MockCallbackExecutor is IOIFCallback {
    event OrderFinalised(bytes executionData);
    event ExecutorOutputFilled(bytes32 token, uint256 amount, bytes executionData);

    function outputFilled(bytes32 token, uint256 amount, bytes calldata executionData) external override {
        emit ExecutorOutputFilled(token, amount, executionData);
    }

    function orderFinalised(
        uint256[2][] calldata,
        /* inputs */
        bytes calldata executionData
    ) external override {
        emit OrderFinalised(executionData);
    }
}
