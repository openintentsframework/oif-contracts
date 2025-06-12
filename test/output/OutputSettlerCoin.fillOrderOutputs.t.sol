// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";

import { IPayloadCreator } from "../../src/interfaces/IPayloadCreator.sol";
import { MandateOutputEncodingLib } from "../../src/libs/MandateOutputEncodingLib.sol";
import { OutputSettlerCoin } from "../../src/output/coin/OutputSettlerCoin.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

contract OutputSettlerCoinTestfillOrderOutputs is Test {
    error AlreadyFilled(bytes32 orderId, bytes32 outputHash);

    event OutputFilled(bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output);

    OutputSettlerCoin outputSettlerCoin;

    MockERC20 outputToken;

    address swapper;
    address outputSettlerCoinAddress;
    address outputTokenAddress;

    function setUp() public {
        outputSettlerCoin = new OutputSettlerCoin();
        outputToken = new MockERC20("TEST", "TEST", 18);

        swapper = makeAddr("swapper");
        outputSettlerCoinAddress = address(outputSettlerCoin);
        outputTokenAddress = address(outputToken);
    }

    /// forge-config: default.isolate = true
    function test_fill_batch_gas() external {
        test_fill_batch_success(
            keccak256(bytes("orderId")),
            makeAddr("sender"),
            keccak256(bytes("filler")),
            keccak256(bytes("nextFiller")),
            10 ** 18,
            10 ** 12
        );
    }

    function test_fill_batch_success(
        bytes32 orderId,
        address sender,
        bytes32 filler,
        bytes32 nextFiller,
        uint128 amount,
        uint128 amount2
    ) public {
        vm.assume(
            filler != bytes32(0) && swapper != sender && nextFiller != filler && nextFiller != bytes32(0)
                && amount != amount2
        );

        outputToken.mint(sender, uint256(amount) + uint256(amount2));
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, uint256(amount) + uint256(amount2));

        MandateOutput[] memory outputs = new MandateOutput[](2);
        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: bytes("")
        });

        outputs[1] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount2,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: bytes("")
        });

        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputs[0]);
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputs[1]);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, amount)
        );
        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, amount2)
        );

        vm.prank(sender);
        outputSettlerCoin.fillOrderOutputs(type(uint32).max, orderId, outputs, filler);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinfillOrderOutputs");

        assertEq(outputToken.balanceOf(swapper), uint256(amount) + uint256(amount2));
        assertEq(outputToken.balanceOf(sender), 0);
    }

    function test_revert_fill_batch_fillDeadline(uint24 fillDeadline, uint24 excess) public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        bytes32 filler = keccak256(bytes("filler"));
        uint128 amount = 10 ** 18;

        outputToken.mint(sender, uint256(amount));
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, uint256(amount));

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: bytes("")
        });

        uint32 warpTo = uint32(excess) + uint32(fillDeadline);
        vm.warp(warpTo);

        if (excess != 0) vm.expectRevert(abi.encodeWithSignature("FillDeadline()"));
        vm.prank(sender);
        outputSettlerCoin.fillOrderOutputs(fillDeadline, orderId, outputs, filler);
    }

    function test_fill_batch_revert_already_filled() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        bytes32 filler = keccak256(bytes("filler"));
        uint128 amount1 = 10 ** 18;
        uint128 amount2 = 2 * 10 ** 18;
        uint128 amount3 = 3 * 10 ** 18;
        uint128 totalAmount = amount1 + amount2 + amount3;

        outputToken.mint(sender, uint256(totalAmount));
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, uint256(totalAmount));

        // Create 3 outputs
        MandateOutput[] memory outputs = new MandateOutput[](3);
        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount1,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: bytes("")
        });

        outputs[1] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount2,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: bytes("")
        });

        outputs[2] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount3,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: bytes("")
        });

        // Fill outputs[1] first
        MandateOutput[] memory singleOutput = new MandateOutput[](1);
        singleOutput[0] = outputs[1];

        vm.prank(sender);
        outputSettlerCoin.fillOrderOutputs(type(uint32).max, orderId, singleOutput, filler);

        // Verify outputs[1] was filled
        assertEq(outputToken.balanceOf(swapper), uint256(amount2));

        // Now try to fill all 3 outputs together, should revert because outputs[1] is already filled
        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHashMemory(outputs[1]);
        vm.expectRevert(abi.encodeWithSelector(AlreadyFilled.selector, orderId, outputHash));
        vm.prank(sender);
        outputSettlerCoin.fillOrderOutputs(type(uint32).max, orderId, outputs, filler);
    }
}
