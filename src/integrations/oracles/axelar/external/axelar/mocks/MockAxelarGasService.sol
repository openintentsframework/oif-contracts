// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

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
