// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { CoinFiller } from "src/fillers/coin/CoinFiller.sol";
import { MandateOutput } from "src/libs/MandateOutputEncodingLib.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";

contract CoinFillerTestCall is Test {
    CoinFiller coinFiller;

    MockERC20 outputToken;

    address swapper;

    function setUp() public {
        coinFiller = new CoinFiller();
        outputToken = new MockERC20("TEST", "TEST", 18);

        swapper = makeAddr("swapper");
    }

    function test_call_with_real_address(address sender, uint256 amount) public {
        vm.assume(sender != address(0));

        MandateOutput memory output = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(address(coinFiller)))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(outputToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            remoteCall: bytes(""),
            fulfillmentContext: bytes("")
        });

        vm.prank(sender);
        vm.expectRevert();
        coinFiller.call(amount, output);
    }

    uint256 storedAmount;

    function test_call_with_real_address(
        uint256 amount
    ) public {
        storedAmount = amount;

        MandateOutput memory output = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(address(coinFiller)))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(outputToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(address(this)))),
            remoteCall: bytes("hello"),
            fulfillmentContext: bytes("")
        });

        vm.prank(address(0));
        coinFiller.call(amount, output);
    }

    function outputFilled(bytes32 token, uint256 amount, bytes calldata executionData) external view {
        assertEq(token, bytes32(uint256(uint160(address(outputToken)))));
        assertEq(amount, storedAmount);
        assertEq(executionData, bytes("hello"));
    }
}
