// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { ICatalystCallback } from "src/interfaces/ICatalystCallback.sol";

contract MockCallbackExecutor is ICatalystCallback {
    event InputsFilled(bytes executionData);
    event ExecutorOutputFilled(bytes32 token, uint256 amount, bytes executionData);

    function outputFilled(bytes32 token, uint256 amount, bytes calldata executionData) external override {
        emit ExecutorOutputFilled(token, amount, executionData);
    }

    function inputsFilled(uint256[2][] calldata, /* inputs */ bytes calldata executionData) external override {
        emit InputsFilled(executionData);
    }
}
