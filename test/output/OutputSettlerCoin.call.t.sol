// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { OutputSettlerCoin } from "../../src/output/coin/OutputSettlerCoin.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

contract OutputSettlerCoinTestCall is Test {
    OutputSettlerCoin outputSettlerCoin;

    MockERC20 outputToken;

    address swapper;

    function setUp() public {
        outputSettlerCoin = new OutputSettlerCoin();
        outputToken = new MockERC20("TEST", "TEST", 18);

        swapper = makeAddr("swapper");
    }

    function test_call_with_real_address(address sender, uint256 amount) public {
        vm.assume(sender != address(0));

        MandateOutput memory output = MandateOutput({
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(outputToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: bytes("")
        });

        vm.prank(sender);
        vm.expectRevert();
        outputSettlerCoin.call(amount, output);
    }

    uint256 storedAmount;

    function test_call_with_real_address(
        uint256 amount
    ) public {
        storedAmount = amount;

        MandateOutput memory output = MandateOutput({
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(outputToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(address(this)))),
            call: bytes("hello"),
            context: bytes("")
        });

        vm.prank(address(0));
        outputSettlerCoin.call(amount, output);
    }

    function outputFilled(bytes32 token, uint256 amount, bytes calldata executionData) external view {
        assertEq(token, bytes32(uint256(uint160(address(outputToken)))));
        assertEq(amount, storedAmount);
        assertEq(executionData, bytes("hello"));
    }
}
