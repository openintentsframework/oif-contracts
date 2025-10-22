// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @notice Mock Axelar Gas Service.
 * Mock implementation of the Axelar Gas Service.
 * Only one function has been implemented to be used in the tests.
 */
contract MockAxelarGasService {
    uint256 public paidGasCounter;

    function payNativeGasForContractCall(
        address,
        string calldata,
        string calldata,
        bytes calldata,
        address
    ) external payable {
        paidGasCounter += 1;
    }
}
