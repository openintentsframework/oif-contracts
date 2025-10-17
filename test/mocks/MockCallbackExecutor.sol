// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IInputCallback } from "../../src/interfaces/IInputCallback.sol";
import { IOutputCallback } from "../../src/interfaces/IOutputCallback.sol";

contract MockCallbackExecutor is IInputCallback, IOutputCallback {
    event OrderFinalised(bytes executionData);
    event ExecutorOutputFilled(bytes32 token, uint256 amount, bytes executionData);

    function outputFilled(
        bytes32 token,
        uint256 amount,
        bytes calldata executionData
    ) external override {
        emit ExecutorOutputFilled(token, amount, executionData);
    }

    receive() external payable { }

    function orderFinalised(
        uint256[2][] calldata,
        /* inputs */
        bytes calldata executionData
    ) external override {
        emit OrderFinalised(executionData);
    }
}
