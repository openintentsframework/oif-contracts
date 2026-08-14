// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockERC20Fallback {
    mapping(address => uint256) public balanceOf;

    receive() external payable { }

    fallback() external payable { }
}
