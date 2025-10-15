// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { OutputSettlerSimple } from "../../src/output/simple/OutputSettlerSimple.sol";

import { MockCallbackExecutor } from "../mocks/MockCallbackExecutor.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

contract OutputSettlerSimpleTestFill is Test {
    error ZeroValue();
    error WrongChain(uint256 expected, uint256 actual);
    error WrongOutputSettler(bytes32 addressThis, bytes32 expected);
    error NotImplemented();
    error SlopeStopped();
    error InsufficientBalance(uint256 balance, uint256 needed);

    event OutputFilled(
        bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output, uint256 finalAmount
    );

    OutputSettlerSimple outputSettlerCoin;

    MockERC20 outputToken;
    MockCallbackExecutor mockCallbackExecutor;

    address swapper;
    address outputSettlerCoinAddress;
    address outputTokenAddress;
    address mockCallbackExecutorAddress;

    function setUp() public {
        outputSettlerCoin = new OutputSettlerSimple();
        outputToken = new MockERC20("TEST", "TEST", 18);
        mockCallbackExecutor = new MockCallbackExecutor();

        swapper = makeAddr("swapper");
        outputSettlerCoinAddress = address(outputSettlerCoin);
        outputTokenAddress = address(outputToken);
        mockCallbackExecutorAddress = address(mockCallbackExecutor);
    }

    // --- VALID CASES --- //

    /// forge-config: default.isolate = true
    function test_fill_gas() external {
        test_fill(keccak256(bytes("orderId")), makeAddr("sender"), keccak256(bytes("filler")), 10 ** 18);
    }

    function test_fill(
        bytes32 orderId,
        address sender,
        bytes32 filler,
        uint256 amount
    ) public {
        vm.assume(filler != bytes32(0) && swapper != sender && sender != address(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);

        bytes memory fillerData = abi.encodePacked(filler);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: bytes("")
        });

        vm.prank(sender);
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), output, amount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, amount)
        );
        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinFill");

        assertEq(outputToken.balanceOf(swapper), amount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    /// forge-config: default.isolate = true
    function test_fill_exclusive_gas() external {
        test_fill_exclusive(
            keccak256(bytes("orderId")),
            makeAddr("sender"),
            10 ** 18,
            keccak256(bytes("exclusiveFor")),
            keccak256(bytes("exclusiveFor")),
            100000,
            1000000
        );
    }

    function test_fill_exclusive(
        bytes32 orderId,
        address sender,
        uint256 amount,
        bytes32 exclusiveFor,
        bytes32 solverIdentifier,
        uint32 startTime,
        uint32 currentTime
    ) public {
        vm.assume(solverIdentifier != bytes32(0) && swapper != sender && sender != address(0));
        vm.warp(currentTime);

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);

        bytes memory context = abi.encodePacked(bytes1(0xe0), exclusiveFor, startTime);
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: context
        });

        bytes memory fillerData = abi.encodePacked(solverIdentifier);

        vm.prank(sender);

        if (exclusiveFor != solverIdentifier && currentTime < startTime) {
            vm.expectRevert(abi.encodeWithSignature("ExclusiveTo(bytes32)", exclusiveFor));
        }
        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinFillExclusive");
    }

    function test_fill_mock_callback_executor(
        address sender,
        bytes32 orderId,
        uint256 amount,
        bytes32 filler,
        bytes memory remoteCallData
    ) public {
        vm.assume(filler != bytes32(0) && sender != address(0));
        vm.assume(sender != mockCallbackExecutorAddress);
        vm.assume(remoteCallData.length != 0);

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(mockCallbackExecutorAddress))),
            callbackData: remoteCallData,
            context: bytes("")
        });
        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        vm.expectCall(
            mockCallbackExecutorAddress,
            abi.encodeWithSignature(
                "outputFilled(bytes32,uint256,bytes)",
                bytes32(uint256(uint160(outputTokenAddress))),
                amount,
                remoteCallData
            )
        );
        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", sender, mockCallbackExecutorAddress, amount
            )
        );

        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), output, amount);
        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);

        assertEq(outputToken.balanceOf(mockCallbackExecutorAddress), amount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    /// forge-config: default.isolate = true
    function test_fill_dutch_auction_gas() external {
        test_fill_dutch_auction(
            keccak256(bytes("orderId")),
            makeAddr("sender"),
            keccak256(bytes("filler")),
            10 ** 18,
            1000,
            500,
            251251,
            1250
        );
    }

    function test_fill_dutch_auction(
        bytes32 orderId,
        address sender,
        bytes32 filler,
        uint128 amount,
        uint16 startTime,
        uint16 runTime,
        uint64 slope,
        uint16 currentTime
    ) public {
        vm.assume(sender != address(0));
        bytes memory context;
        uint256 finalAmount;
        {
            uint32 stopTime = uint32(startTime) + uint32(runTime);
            vm.assume(filler != bytes32(0) && swapper != sender);
            vm.warp(currentTime);

            uint256 minAmount = amount;
            uint256 maxAmount = amount + uint256(slope) * uint256(stopTime - startTime);
            finalAmount = startTime > currentTime
                ? maxAmount
                : (stopTime < currentTime ? minAmount : (amount + uint256(slope) * uint256(stopTime - currentTime)));

            outputToken.mint(sender, finalAmount);
            vm.prank(sender);
            outputToken.approve(outputSettlerCoinAddress, finalAmount);

            context = abi.encodePacked(
                bytes1(0x01), bytes4(uint32(startTime)), bytes4(uint32(stopTime)), bytes32(uint256(slope))
            );
        }

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: context
        });

        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);

        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), output, finalAmount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, finalAmount)
        );
        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinFillDutchAuction");

        assertEq(outputToken.balanceOf(swapper), finalAmount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    /// forge-config: default.isolate = true
    function test_fill_exclusive_dutch_auction_gas() external {
        test_fill_exclusive_dutch_auction(
            keccak256(bytes("orderId")),
            makeAddr("sender"),
            10 ** 18,
            1000,
            500,
            251251,
            1250,
            keccak256(bytes("exclusiveFor"))
        );
    }

    function test_fill_exclusive_dutch_auction(
        bytes32 orderId,
        address sender,
        uint128 amount,
        uint16 startTime,
        uint16 runTime,
        uint64 slope,
        uint16 currentTime,
        bytes32 exclusiveFor
    ) public {
        vm.assume(sender != address(0));
        bytes memory context;
        uint256 finalAmount;
        {
            uint32 stopTime = uint32(startTime) + uint32(runTime);
            vm.assume(exclusiveFor != bytes32(0) && swapper != sender);
            vm.warp(currentTime);

            uint256 minAmount = amount;
            uint256 maxAmount = amount + uint256(slope) * uint256(stopTime - startTime);
            finalAmount = startTime > currentTime
                ? maxAmount
                : (stopTime < currentTime ? minAmount : (amount + uint256(slope) * uint256(stopTime - currentTime)));

            outputToken.mint(sender, finalAmount);
            vm.prank(sender);
            outputToken.approve(outputSettlerCoinAddress, finalAmount);

            context = abi.encodePacked(
                bytes1(0xe1),
                bytes32(exclusiveFor),
                bytes4(uint32(startTime)),
                bytes4(uint32(stopTime)),
                bytes32(uint256(slope))
            );
        }
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: context
        });

        bytes memory fillerData = abi.encodePacked(exclusiveFor);

        vm.prank(sender);

        vm.expectEmit();
        emit OutputFilled(orderId, exclusiveFor, uint32(block.timestamp), output, finalAmount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, finalAmount)
        );

        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinFillExclusiveDutchAuction");

        assertEq(outputToken.balanceOf(swapper), finalAmount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    function test_fill_revert_exclusive_for_another_dutch_auction(
        bytes32 orderId,
        address sender,
        uint128 amount,
        uint16 startTime,
        uint16 runTime,
        uint64 slope,
        uint16 currentTime,
        bytes32 exclusiveFor,
        bytes32 solverIdentifier
    ) public {
        vm.assume(sender != address(0));
        bytes memory context;
        {
            uint32 stopTime = uint32(startTime) + uint32(runTime);
            vm.assume(solverIdentifier != bytes32(0) && swapper != sender);
            vm.assume(solverIdentifier != exclusiveFor);
            vm.warp(currentTime);

            context = abi.encodePacked(
                bytes1(0xe1),
                bytes32(exclusiveFor),
                bytes4(uint32(startTime)),
                bytes4(uint32(stopTime)),
                bytes32(uint256(slope))
            );

            uint256 maxAmount = amount + uint256(slope) * uint256(stopTime - startTime);
            uint256 finalAmount = startTime > currentTime
                ? maxAmount
                : (stopTime < currentTime ? amount : (amount + uint256(slope) * uint256(stopTime - currentTime)));

            outputToken.mint(sender, finalAmount);
            vm.prank(sender);
            outputToken.approve(outputSettlerCoinAddress, finalAmount);
        }

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: context
        });

        vm.prank(sender);
        if (startTime > currentTime) vm.expectRevert(abi.encodeWithSignature("ExclusiveTo(bytes32)", exclusiveFor));
        outputSettlerCoin.fill(orderId, output, type(uint48).max, abi.encodePacked(solverIdentifier));
    }

    // --- FAILURE CASES --- //

    function test_fill_zero_filler(
        address sender,
        bytes32 orderId
    ) public {
        bytes32 filler = bytes32(0);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: 0,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: bytes("")
        });

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(ZeroValue.selector);
        vm.prank(sender);
        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);
    }

    function test_invalid_chain_id(
        address sender,
        bytes32 filler,
        bytes32 orderId,
        uint256 chainId
    ) public {
        vm.assume(chainId != block.chainid);
        vm.assume(filler != bytes32(0));
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(0),
            chainId: chainId,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            callbackData: bytes(""),
            context: bytes("")
        });
        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, chainId, block.chainid));
        vm.prank(sender);
        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);
    }

    function test_invalid_filler(
        address sender,
        bytes32 filler,
        bytes32 orderId,
        bytes32 fillerOracleBytes
    ) public {
        bytes32 outputSettlerCoinOracleBytes = bytes32(uint256(uint160(outputSettlerCoinAddress)));

        vm.assume(fillerOracleBytes != outputSettlerCoinOracleBytes);
        vm.assume(filler != bytes32(0));
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: fillerOracleBytes,
            chainId: block.chainid,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            callbackData: bytes(""),
            context: bytes("")
        });

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(
            abi.encodeWithSelector(WrongOutputSettler.selector, outputSettlerCoinOracleBytes, fillerOracleBytes)
        );
        vm.prank(sender);
        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);
    }

    function test_revert_fill_deadline_passed(
        address sender,
        bytes32 filler,
        bytes32 orderId,
        uint48 fillDeadline,
        uint48 filledAt
    ) public {
        vm.assume(filler != bytes32(0));
        vm.assume(fillDeadline < filledAt);

        vm.warp(filledAt);
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            callbackData: bytes(""),
            context: bytes("")
        });

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(abi.encodeWithSignature("FillDeadline()"));
        vm.prank(sender);
        outputSettlerCoin.fill(orderId, output, fillDeadline, fillerData);
    }

    function test_fill_made_already(
        address sender,
        bytes32 filler,
        bytes32 differentFiller,
        bytes32 orderId,
        uint256 amount
    ) public {
        vm.assume(filler != bytes32(0) && sender != address(0));
        vm.assume(filler != differentFiller && differentFiller != bytes32(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(sender))),
            callbackData: bytes(""),
            context: bytes("")
        });

        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);

        bytes memory differentFillerData = abi.encodePacked(differentFiller);
        vm.prank(sender);
        bytes32 alreadyFilledBy = outputSettlerCoin.fill(orderId, output, type(uint48).max, differentFillerData);

        assertNotEq(alreadyFilledBy, keccak256(abi.encodePacked(differentFiller, uint32(block.timestamp))));
        assertEq(alreadyFilledBy, keccak256(abi.encodePacked(filler, uint32(block.timestamp))));
    }

    function test_invalid_fulfillment_context(
        address sender,
        bytes32 filler,
        bytes32 orderId,
        uint256 amount,
        bytes memory outputContext
    ) public {
        vm.assume(bytes1(outputContext) != 0x00 && outputContext.length != 1);
        vm.assume(bytes1(outputContext) != 0x01 && outputContext.length != 41);
        vm.assume(bytes1(outputContext) != 0xe0 && outputContext.length != 37);
        vm.assume(bytes1(outputContext) != 0xe1 && outputContext.length != 73);
        vm.assume(filler != bytes32(0) && sender != address(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: outputContext
        });

        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        vm.expectRevert(NotImplemented.selector);
        outputSettlerCoin.fill(orderId, output, type(uint48).max, fillerData);
    }

    // --- NATIVE TOKEN TESTS --- //

    /// forge-config: default.isolate = true
    function test_fill_native_token_gas() external {
        test_fill_native_token(keccak256(bytes("orderId")), makeAddr("sender"), keccak256(bytes("filler")), 10 ** 18);
    }

    function test_fill_native_token(
        bytes32 orderId,
        address sender,
        bytes32 filler,
        uint256 amount
    ) public {
        vm.assume(
            filler != bytes32(0) && swapper != address(0) && swapper != sender && sender != address(0) && amount > 0
        );
        vm.deal(sender, amount);

        bytes memory fillerData = abi.encodePacked(filler);

        uint256 swapperBalanceBefore = swapper.balance;

        MandateOutput memory outputStruct = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(0),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: bytes("")
        });

        vm.prank(sender);
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputStruct, amount);

        outputSettlerCoin.fill{ value: amount }(orderId, outputStruct, type(uint48).max, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinFillNative");

        assertEq(swapper.balance, swapperBalanceBefore + amount);
        assertEq(sender.balance, 0);
    }

    function test_fill_native_token_with_excess_refund(
        bytes32 orderId,
        bytes32 filler,
        uint256 amount
    ) public {
        vm.assume(filler != bytes32(0));
        vm.assume(amount > 0 && amount < type(uint256).max - 1);

        address sender = makeAddr("sender");

        uint256 totalValue = amount + 1;
        vm.deal(sender, totalValue);

        bytes memory fillerData = abi.encodePacked(filler);

        uint256 swapperBalanceBefore = swapper.balance;
        uint256 senderBalanceBefore = sender.balance;

        MandateOutput memory outputStruct = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(0),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: bytes("")
        });

        vm.prank(sender);
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputStruct, amount);

        outputSettlerCoin.fill{ value: totalValue }(orderId, outputStruct, type(uint48).max, fillerData);

        assertEq(swapper.balance, swapperBalanceBefore + amount);
        assertEq(sender.balance, senderBalanceBefore - amount); // Should get excess back
    }

    function test_fill_native_token_insufficient_value(
        bytes32 orderId,
        bytes32 filler,
        uint256 amount,
        uint256 sentValue
    ) public {
        vm.assume(filler != bytes32(0));
        vm.assume(amount > 0 && sentValue < amount);

        address sender = makeAddr("sender");
        vm.deal(sender, sentValue);

        bytes memory fillerData = abi.encodePacked(filler);

        MandateOutput memory outputStruct = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(0),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: bytes("")
        });

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(InsufficientBalance.selector, sentValue, amount));
        outputSettlerCoin.fill{ value: sentValue }(orderId, outputStruct, type(uint48).max, fillerData);
    }

    function test_fill_native_token_zero_amount(
        bytes32 orderId,
        bytes32 filler
    ) public {
        vm.assume(filler != bytes32(0));

        address sender = makeAddr("sender");
        vm.deal(sender, 1 ether);

        bytes memory fillerData = abi.encodePacked(filler);

        uint256 swapperBalanceBefore = swapper.balance;
        uint256 senderBalanceBefore = sender.balance;

        MandateOutput memory outputStruct = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: bytes("")
        });

        vm.prank(sender);
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputStruct, 0);

        outputSettlerCoin.fill{ value: 1 ether }(orderId, outputStruct, type(uint48).max, fillerData);

        assertEq(swapper.balance, swapperBalanceBefore); // No change for zero amount
        assertEq(sender.balance, senderBalanceBefore); // Should get full refund
    }

    function test_fill_native_token_already_filled(
        bytes32 filler,
        bytes32 differentFiller,
        bytes32 orderId,
        uint256 amount
    ) public {
        vm.assume(filler != bytes32(0) && amount > 0);
        vm.assume(filler != differentFiller && differentFiller != bytes32(0));

        address sender = makeAddr("sender");
        vm.deal(sender, amount);

        bytes memory fillerData = abi.encodePacked(filler);

        MandateOutput memory outputStruct = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(0),
            amount: amount / 2,
            recipient: bytes32(uint256(uint160(sender))),
            callbackData: bytes(""),
            context: bytes("")
        });

        // First fill
        vm.prank(sender);
        outputSettlerCoin.fill{ value: amount / 2 }(orderId, outputStruct, type(uint48).max, fillerData);

        // Second fill attempt (should return existing fill record, no additional transfer)
        bytes memory differentFillerData = abi.encodePacked(differentFiller);
        uint256 senderBalanceBeforeSecond = sender.balance;

        vm.prank(sender);
        bytes32 alreadyFilledBy =
            outputSettlerCoin.fill{ value: amount / 2 }(orderId, outputStruct, type(uint48).max, differentFillerData);

        assertNotEq(alreadyFilledBy, keccak256(abi.encodePacked(differentFiller, uint32(block.timestamp))));
        assertEq(alreadyFilledBy, keccak256(abi.encodePacked(filler, uint32(block.timestamp))));

        // Should get full refund for second attempt since no native tokens used
        assertEq(sender.balance, senderBalanceBeforeSecond);
    }

    function test_fill_native_token_with_callback(
        bytes32 orderId,
        uint256 amount,
        bytes32 filler,
        bytes memory callbackData
    ) public {
        vm.assume(filler != bytes32(0) && amount > 0);
        vm.assume(callbackData.length > 0);

        address sender = makeAddr("sender");
        vm.deal(sender, amount);

        bytes memory fillerData = abi.encodePacked(filler);

        MandateOutput memory outputStruct = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(0),
            amount: amount,
            recipient: bytes32(uint256(uint160(mockCallbackExecutorAddress))),
            callbackData: callbackData,
            context: bytes("")
        });

        vm.prank(sender);
        vm.expectCall(
            mockCallbackExecutorAddress,
            abi.encodeWithSignature(
                "outputFilled(bytes32,uint256,bytes)",
                bytes32(0), // native token identifier
                amount,
                callbackData
            )
        );

        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputStruct, amount);

        outputSettlerCoin.fill{ value: amount }(orderId, outputStruct, type(uint48).max, fillerData);

        assertEq(mockCallbackExecutorAddress.balance, amount);
        assertEq(sender.balance, 0);
    }

    function test_fill_erc20_with_native_value_sent_gets_refunded(
        bytes32 orderId,
        bytes32 filler,
        uint256 tokenAmount,
        uint256 nativeValue
    ) public {
        address sender = makeAddr("sender");

        vm.assume(filler != bytes32(0) && swapper != address(0) && swapper != sender);
        vm.assume(tokenAmount > 0 && nativeValue > 0);

        outputToken.mint(sender, tokenAmount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, tokenAmount);
        vm.deal(sender, nativeValue);

        bytes memory fillerData = abi.encodePacked(filler);

        uint256 swapperBalanceBefore = swapper.balance;
        uint256 senderBalanceBefore = sender.balance;

        MandateOutput memory outputStruct = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: tokenAmount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: bytes("")
        });

        vm.prank(sender);
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputStruct, tokenAmount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, tokenAmount)
        );

        outputSettlerCoin.fill{ value: nativeValue }(orderId, outputStruct, type(uint48).max, fillerData);

        // ERC20 transfer should work
        assertEq(outputToken.balanceOf(swapper), tokenAmount);
        assertEq(outputToken.balanceOf(sender), 0);

        // Native value should be refunded (no native tokens used)
        assertEq(swapper.balance, swapperBalanceBefore);
        assertEq(sender.balance, senderBalanceBefore); // Full refund
    }
}
