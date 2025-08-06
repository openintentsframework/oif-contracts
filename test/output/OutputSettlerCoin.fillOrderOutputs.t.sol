// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { OutputSettlerResolver } from "../../src/output/OutputSettlerResolver.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

contract OutputSettlerCoinTestfillOrderOutputs is Test {
    error FilledBySomeoneElse(bytes32 solver);

    event OutputFilled(bytes32 indexed orderId, bytes32 solver, uint32 timestamp, bytes output, uint256 finalAmount);

    OutputSettlerResolver outputSettlerCoin;

    MockERC20 outputToken;

    address swapper;
    address outputSettlerCoinAddress;
    address outputTokenAddress;

    function setUp() public {
        outputSettlerCoin = new OutputSettlerResolver();
        outputToken = new MockERC20("TEST", "TEST", 18);

        swapper = makeAddr("swapper");
        outputSettlerCoinAddress = address(outputSettlerCoin);
        outputTokenAddress = address(outputToken);
    }

    /// forge-config: default.isolate = true
    function test_fill_batch_gas() external {
        test_fill_batch(
            keccak256(bytes("orderId")),
            makeAddr("sender"),
            keccak256(bytes("filler")),
            keccak256(bytes("nextFiller")),
            10 ** 18,
            10 ** 12
        );
    }

    function test_fill_batch(
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

        bytes[] memory outputs = new bytes[](2);

        outputs[0] = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerCoinAddress))), // settler
            uint256(block.chainid), // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            uint256(amount), //amount
            bytes32(uint256(uint160(swapper))), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(0), // context length
            bytes("") // context
        );

        outputs[1] = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerCoinAddress))), // settler
            uint256(block.chainid), // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            uint256(amount2), //amount
            bytes32(uint256(uint160(swapper))), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(0), // context length
            bytes("") // context
        );

        bytes memory fillerData = abi.encodePacked(filler);
        bytes memory nextFillerData = abi.encodePacked(nextFiller);

        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputs[0], amount);
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputs[1], amount2);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, amount)
        );
        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, amount2)
        );

        uint256 prefillSnapshot = vm.snapshot();

        vm.prank(sender);
        outputSettlerCoin.fillOrderOutputs(orderId, outputs, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinfillOrderOutputs");

        assertEq(outputToken.balanceOf(swapper), uint256(amount) + uint256(amount2));
        assertEq(outputToken.balanceOf(sender), 0);

        vm.revertTo(prefillSnapshot);
        // Fill the first output by someone else. The other outputs won't be filled.
        vm.prank(sender);
        outputSettlerCoin.fill(orderId, outputs[0], nextFillerData);

        vm.expectRevert(abi.encodeWithSignature("AlreadyFilled()"));
        vm.prank(sender);
        outputSettlerCoin.fillOrderOutputs(orderId, outputs, fillerData);

        vm.revertTo(prefillSnapshot);
        // Fill the second output by someone else. The first output will be filled.

        vm.prank(sender);
        outputSettlerCoin.fill(orderId, outputs[1], nextFillerData);

        vm.prank(sender);
        outputSettlerCoin.fillOrderOutputs(orderId, outputs, fillerData);
    }

    function test_revert_fill_batch_fillDeadline(uint24 fillDeadline, uint24 excess) public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        bytes32 filler = keccak256(bytes("filler"));
        uint128 amount = 10 ** 18;

        outputToken.mint(sender, uint256(amount));
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, uint256(amount));

        bytes[] memory outputs = new bytes[](1);

        bytes memory output = abi.encodePacked(
            uint48(fillDeadline), // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerCoinAddress))), // settler
            uint256(block.chainid), // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            uint256(amount), //amount
            bytes32(uint256(uint160(swapper))), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(0), // context length
            bytes("") // context
        );

        outputs[0] = output;

        bytes memory fillerData = abi.encodePacked(filler);

        uint32 warpTo = uint32(excess) + uint32(fillDeadline);
        vm.warp(warpTo);

        if (excess != 0) vm.expectRevert(abi.encodeWithSignature("FillDeadline()"));
        vm.prank(sender);
        outputSettlerCoin.fillOrderOutputs(orderId, outputs, fillerData);
    }
}
