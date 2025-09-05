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

    event OutputFilled(bytes32 indexed orderId, bytes32 solver, uint32 timestamp, bytes output, uint256 finalAmount);

    OutputSettlerSimple outputSettlerSimple;

    MockERC20 outputToken;
    MockCallbackExecutor mockCallbackExecutor;

    address swapper;
    address outputSettlerSimpleAddress;
    address outputTokenAddress;
    address mockCallbackExecutorAddress;

    function setUp() public {
        outputSettlerSimple = new OutputSettlerSimple();
        outputToken = new MockERC20("TEST", "TEST", 18);
        mockCallbackExecutor = new MockCallbackExecutor();

        swapper = makeAddr("swapper");
        outputSettlerSimpleAddress = address(outputSettlerSimple);
        outputTokenAddress = address(outputToken);
        mockCallbackExecutorAddress = address(mockCallbackExecutor);
    }

    // --- VALID CASES --- //

    /// forge-config: default.isolate = true
    function test_fill_gas() external {
        test_fill(keccak256(bytes("orderId")), makeAddr("sender"), keccak256(bytes("filler")), 10 ** 18);
    }

    function test_fill(bytes32 orderId, address sender, bytes32 filler, uint256 amount) public {
        vm.assume(filler != bytes32(0) && swapper != sender && sender != address(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerSimpleAddress, amount);

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            block.chainid, // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            amount, //amount
            bytes32(uint256(uint160(swapper))), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(0), // context length
            bytes("") // context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), output, amount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, amount)
        );

        outputSettlerSimple.fill(orderId, output, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerSimpleFill");

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
        outputToken.approve(outputSettlerSimpleAddress, amount);

        bytes memory context = abi.encodePacked(bytes1(0xe0), exclusiveFor, startTime);

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            block.chainid, // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            amount, //amount
            bytes32(uint256(uint160(swapper))), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(context.length), // context length
            context // context
        );

        bytes memory fillerData = abi.encodePacked(solverIdentifier);

        vm.prank(sender);

        if (exclusiveFor != solverIdentifier && currentTime < startTime) {
            vm.expectRevert(abi.encodeWithSignature("ExclusiveTo(bytes32)", exclusiveFor));
        }
        outputSettlerSimple.fill(orderId, output, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerSimpleFillExclusive");
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
        outputToken.approve(outputSettlerSimpleAddress, amount);

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            block.chainid, // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            amount, //amount
            bytes32(uint256(uint160(mockCallbackExecutorAddress))), // recipient
            uint16(remoteCallData.length), // call length
            remoteCallData, // call
            uint16(0), // context length
            bytes("") // context
        );

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

        outputSettlerSimple.fill(orderId, output, fillerData);

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
            outputToken.approve(outputSettlerSimpleAddress, finalAmount);

            context = abi.encodePacked(
                bytes1(0x01), bytes4(uint32(startTime)), bytes4(uint32(stopTime)), bytes32(uint256(slope))
            );
        }

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            block.chainid, // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            uint256(amount), //amount
            bytes32(uint256(uint160(swapper))), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(context.length), // context length
            context // context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);

        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), output, finalAmount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, finalAmount)
        );
        outputSettlerSimple.fill(orderId, output, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerSimpleFillDutchAuction");

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
            outputToken.approve(outputSettlerSimpleAddress, finalAmount);

            context = abi.encodePacked(
                bytes1(0xe1),
                bytes32(exclusiveFor),
                bytes4(uint32(startTime)),
                bytes4(uint32(stopTime)),
                bytes32(uint256(slope))
            );
        }

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            block.chainid, // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            uint256(amount), //amount
            bytes32(uint256(uint160(swapper))), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(context.length), // context length
            context // context
        );

        bytes memory fillerData = abi.encodePacked(exclusiveFor);

        vm.prank(sender);

        vm.expectEmit();
        emit OutputFilled(orderId, exclusiveFor, uint32(block.timestamp), output, finalAmount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, finalAmount)
        );

        outputSettlerSimple.fill(orderId, output, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerSimpleFillExclusiveDutchAuction");

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
            outputToken.approve(outputSettlerSimpleAddress, finalAmount);
        }

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            block.chainid, // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            uint256(amount), //amount
            bytes32(uint256(uint160(swapper))), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(context.length), // context length
            context
        );

        vm.prank(sender);
        if (startTime > currentTime) vm.expectRevert(abi.encodeWithSignature("ExclusiveTo(bytes32)", exclusiveFor));
        outputSettlerSimple.fill(orderId, output, abi.encodePacked(solverIdentifier));
    }

    // --- FAILURE CASES --- //

    function test_fill_zero_filler(address sender, bytes32 orderId) public {
        bytes32 filler = bytes32(0);

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            uint256(block.chainid), // chainId
            bytes32(0), // token
            uint256(0), //amount
            bytes32(0), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(0), // context length
            bytes("") // context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(ZeroValue.selector);
        vm.prank(sender);
        outputSettlerSimple.fill(orderId, output, fillerData);
    }

    function test_invalid_chain_id(address sender, bytes32 filler, bytes32 orderId, uint256 chainId) public {
        vm.assume(chainId != block.chainid);
        vm.assume(filler != bytes32(0));

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(0), // settler
            chainId, // chainId
            bytes32(0), // token
            uint256(0), // amount
            bytes32(0), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(0), // context length
            bytes("") // context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, chainId, block.chainid));
        vm.prank(sender);
        outputSettlerSimple.fill(orderId, output, fillerData);
    }

    function test_invalid_filler(address sender, bytes32 filler, bytes32 orderId, bytes32 fillerOracleBytes) public {
        bytes32 outputSettlerSimpleOracleBytes = bytes32(uint256(uint160(outputSettlerSimpleAddress)));

        vm.assume(fillerOracleBytes != outputSettlerSimpleOracleBytes);
        vm.assume(filler != bytes32(0));

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            fillerOracleBytes, // settler
            uint256(block.chainid), // chainId
            bytes32(0), // token
            uint256(0), // amount
            bytes32(0), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(0), // context length
            bytes("") // context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(
            abi.encodeWithSelector(WrongOutputSettler.selector, outputSettlerSimpleOracleBytes, fillerOracleBytes)
        );
        vm.prank(sender);
        outputSettlerSimple.fill(orderId, output, fillerData);
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

        bytes memory output = abi.encodePacked(
            uint48(fillDeadline), // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            uint256(block.chainid), // chainId
            bytes32(0), // token
            uint256(0), // amount
            bytes32(0), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(0), // context length
            bytes("") // context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(abi.encodeWithSignature("FillDeadline()"));
        vm.prank(sender);
        outputSettlerSimple.fill(orderId, output, fillerData);
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
        outputToken.approve(outputSettlerSimpleAddress, amount);

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            block.chainid, // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            amount, //amount
            bytes32(uint256(uint160(sender))), // recipient,
            uint16(0), // call length
            bytes(""), // call
            uint16(0), // context length
            bytes("")
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        outputSettlerSimple.fill(orderId, output, fillerData);

        bytes memory differentFillerData = abi.encodePacked(differentFiller);
        vm.prank(sender);
        bytes32 alreadyFilledBy = outputSettlerSimple.fill(orderId, output, differentFillerData);

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
        outputToken.approve(outputSettlerSimpleAddress, amount);

        bytes memory output = abi.encodePacked(
            type(uint48).max, // fill deadline
            bytes32(0), // oracle
            bytes32(uint256(uint160(outputSettlerSimpleAddress))), // settler
            block.chainid, // chainId
            bytes32(uint256(uint160(outputTokenAddress))), // token
            amount, //amount
            bytes32(uint256(uint160(swapper))), // recipient
            uint16(0), // call length
            bytes(""), // call
            uint16(outputContext.length), // context length
            outputContext // context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        vm.expectRevert(NotImplemented.selector);
        outputSettlerSimple.fill(orderId, output, fillerData);
    }
}
