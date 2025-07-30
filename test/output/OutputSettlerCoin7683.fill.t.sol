// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { OutputSettlerCoin } from "../../src/output/coin/OutputSettlerCoin.sol";

import { MockCallbackExecutor } from "../mocks/MockCallbackExecutor.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

contract OutputSettlerCoinTestFill is Test {
    error ZeroValue();
    error WrongChain(uint256 expected, uint256 actual);
    error WrongOutputSettler(bytes32 addressThis, bytes32 expected);
    error NotImplemented();
    error SlopeStopped();

    event OutputFilled(
        bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output, uint256 finalAmount
    );

    OutputSettlerCoin outputSettlerCoin;

    MockERC20 outputToken;
    MockCallbackExecutor mockCallbackExecutor;

    address swapper;
    address outputSettlerCoinAddress;
    address outputTokenAddress;
    address mockCallbackExecutorAddress;

    function setUp() public {
        outputSettlerCoin = new OutputSettlerCoin();
        outputToken = new MockERC20("TEST", "TEST", 18);
        mockCallbackExecutor = new MockCallbackExecutor();

        swapper = makeAddr("swapper");
        outputSettlerCoinAddress = address(outputSettlerCoin);
        outputTokenAddress = address(outputToken);
        mockCallbackExecutorAddress = address(mockCallbackExecutor);
    }

    // --- VALID CASES --- //

    /// forge-config: default.isolate = true
    // function test_fill_gas() external {
    //     test_fill(keccak256(bytes("orderId")), makeAddr("sender"), keccak256(bytes("filler")), 10 ** 18);
    // }

    function test_fill() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        bytes32 filler = keccak256(bytes("filler"));
        uint256 amount = 10 ** 18;
        vm.assume(filler != bytes32(0) && swapper != sender);

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);

        MandateOutput memory output = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: bytes("")
        });

        vm.prank(sender);
        // vm.expectEmit();
        // emit OutputFilled(orderId, filler, uint32(block.timestamp), output, output.amount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, amount)
        );

        bytes memory outputBytes = abi.encodePacked(
            output.oracle,
            output.settler,
            output.chainId,
            output.token,
            output.amount,
            output.recipient,
            uint16(output.call.length), // To protect against data collisions
            output.call,
            uint16(output.context.length), // To protect against data collisions
            output.context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        //outputSettlerCoin.fill(type(uint32).max, orderId, output, filler);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinFill");

        assertEq(outputToken.balanceOf(swapper), amount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    /// forge-config: default.isolate = true
    // function test_fill_exclusive_gas() external {
    //     test_fill_exclusive(
    //         keccak256(bytes("orderId")),
    //         makeAddr("sender"),
    //         10 ** 18,
    //         keccak256(bytes("exclusiveFor")),
    //         keccak256(bytes("exclusiveFor")),
    //         100000,
    //         1000000
    //     );
    // }

    function test_fill_exclusive() public {
        // vm.assume(solverIdentifier != bytes32(0) && swapper != sender);
        // vm.warp(currentTime);

        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        uint256 amount = 10 ** 18;
        bytes32 exclusiveFor = keccak256(bytes("exclusiveFor"));
        bytes32 solverIdentifier = keccak256(bytes("exclusiveFor"));
        uint32 startTime = 100000;
        uint32 currentTime = 1000000;

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);

        MandateOutput memory output = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: abi.encodePacked(bytes1(0xe0), exclusiveFor, startTime)
        });

        bytes memory outputBytes = abi.encodePacked(
            output.oracle,
            output.settler,
            output.chainId,
            output.token,
            output.amount,
            output.recipient,
            uint16(output.call.length), // To protect against data collisions
            output.call,
            uint16(output.context.length), // To protect against data collisions
            output.context
        );

        bytes memory fillerData = abi.encodePacked(solverIdentifier);

        vm.prank(sender);

        if (exclusiveFor != solverIdentifier && currentTime < startTime) {
            vm.expectRevert(abi.encodeWithSignature("ExclusiveTo(bytes32)", exclusiveFor));
        }
        //outputSettlerCoin.fill(type(uint32).max, orderId, output, solverIdentifier);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);

        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinFillExclusive");
    }

    function test_fill_mock_callback_executor(
        address sender,
        bytes32 orderId,
        uint256 amount,
        bytes32 filler,
        bytes memory remoteCallData
    ) public {
        vm.assume(filler != bytes32(0));
        vm.assume(sender != mockCallbackExecutorAddress);
        vm.assume(remoteCallData.length != 0);

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(mockCallbackExecutorAddress))),
            call: remoteCallData,
            context: bytes("")
        });

        bytes memory outputBytes = abi.encodePacked(
            outputs[0].oracle,
            outputs[0].settler,
            outputs[0].chainId,
            outputs[0].token,
            outputs[0].amount,
            outputs[0].recipient,
            uint16(outputs[0].call.length), // To protect against data collisions
            outputs[0].call,
            uint16(outputs[0].context.length), // To protect against data collisions
            outputs[0].context
        );

        vm.prank(sender);
        vm.expectCall(
            mockCallbackExecutorAddress,
            abi.encodeWithSignature(
                "outputFilled(bytes32,uint256,bytes)", outputs[0].token, outputs[0].amount, remoteCallData
            )
        );
        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", sender, mockCallbackExecutorAddress, amount
            )
        );

        // vm.expectEmit();
        // emit OutputFilled(orderId, filler, uint32(block.timestamp), outputs[0], outputs[0].amount);

        bytes memory fillerData = abi.encodePacked(filler);

        //outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], filler);

        outputSettlerCoin.fill(orderId, outputBytes, fillerData);

        assertEq(outputToken.balanceOf(mockCallbackExecutorAddress), amount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    /// forge-config: default.isolate = true
    // function test_fill_dutch_auction_gas() external {
    //     test_fill_dutch_auction(
    //         keccak256(bytes("orderId")),
    //         makeAddr("sender"),
    //         keccak256(bytes("filler")),
    //         10 ** 18,
    //         1000,
    //         500,
    //         251251,
    //         1250
    //     );
    // }

    function test_fill_dutch_auction() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        bytes32 filler = keccak256(bytes("filler"));
        uint256 amount = 10 ** 18;
        uint16 startTime = 1000;
        uint16 runTime = 500;
        uint64 slope = 251251;
        uint16 currentTime = 1250;

        uint32 stopTime = uint32(startTime) + uint32(runTime);
        vm.assume(filler != bytes32(0) && swapper != sender);
        vm.warp(currentTime);

        uint256 minAmount = amount;
        uint256 maxAmount = amount + uint256(slope) * uint256(stopTime - startTime);
        uint256 finalAmount = startTime > currentTime
            ? maxAmount
            : (stopTime < currentTime ? minAmount : (amount + uint256(slope) * uint256(stopTime - currentTime)));

        outputToken.mint(sender, finalAmount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, finalAmount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: abi.encodePacked(
                bytes1(0x01), bytes4(uint32(startTime)), bytes4(uint32(stopTime)), bytes32(uint256(slope))
            )
        });

        bytes memory outputBytes = abi.encodePacked(
            outputs[0].oracle,
            outputs[0].settler,
            outputs[0].chainId,
            outputs[0].token,
            outputs[0].amount,
            outputs[0].recipient,
            uint16(outputs[0].call.length), // To protect against data collisions
            outputs[0].call,
            uint16(outputs[0].context.length), // To protect against data collisions
            outputs[0].context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);

        // vm.expectEmit();
        // emit OutputFilled(orderId, filler, uint32(block.timestamp), outputs[0], finalAmount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, finalAmount)
        );
        //outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], filler);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
        vm.snapshotGasLastCall("outputSettler", "outputSettlerCoinFillDutchAuction");

        assertEq(outputToken.balanceOf(swapper), finalAmount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    /// forge-config: default.isolate = true
    // function test_fill_exclusive_dutch_auction_gas() external {
    //     test_fill_exclusive_dutch_auction(
    //         keccak256(bytes("orderId")),
    //         makeAddr("sender"),
    //         10 ** 18,
    //         1000,
    //         500,
    //         251251,
    //         1250,
    //         keccak256(bytes("exclusiveFor"))
    //     );
    // }

    function test_fill_exclusive_dutch_auction() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        uint256 amount = 10 ** 18;
        uint16 startTime = 1000;
        uint16 runTime = 500;
        uint64 slope = 251251;
        uint16 currentTime = 1250;
        bytes32 exclusiveFor = keccak256(bytes("exclusiveFor"));

        uint32 stopTime = uint32(startTime) + uint32(runTime);
        vm.assume(exclusiveFor != bytes32(0) && swapper != sender);
        vm.warp(currentTime);

        uint256 minAmount = amount;
        uint256 maxAmount = amount + uint256(slope) * uint256(stopTime - startTime);
        uint256 finalAmount = startTime > currentTime
            ? maxAmount
            : (stopTime < currentTime ? minAmount : (amount + uint256(slope) * uint256(stopTime - currentTime)));

        outputToken.mint(sender, finalAmount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, finalAmount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: abi.encodePacked(
                bytes1(0xe1),
                bytes32(exclusiveFor),
                bytes4(uint32(startTime)),
                bytes4(uint32(stopTime)),
                bytes32(uint256(slope))
            )
        });

        bytes memory outputBytes = abi.encodePacked(
            outputs[0].oracle,
            outputs[0].settler,
            outputs[0].chainId,
            outputs[0].token,
            outputs[0].amount,
            outputs[0].recipient,
            uint16(outputs[0].call.length), // To protect against data collisions
            outputs[0].call,
            uint16(outputs[0].context.length), // To protect against data collisions
            outputs[0].context
        );

        bytes memory fillerData = abi.encodePacked(exclusiveFor);

        vm.prank(sender);

        //vm.expectEmit();
        //emit OutputFilled(orderId, exclusiveFor, uint32(block.timestamp), outputs[0], finalAmount);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, finalAmount)
        );

        //outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], exclusiveFor);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
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
        uint32 stopTime = uint32(startTime) + uint32(runTime);
        vm.assume(solverIdentifier != bytes32(0) && swapper != sender);
        vm.assume(solverIdentifier != exclusiveFor);
        vm.warp(currentTime);

        uint256 maxAmount = amount + uint256(slope) * uint256(stopTime - startTime);
        uint256 finalAmount = startTime > currentTime
            ? maxAmount
            : (stopTime < currentTime ? amount : (amount + uint256(slope) * uint256(stopTime - currentTime)));

        outputToken.mint(sender, finalAmount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, finalAmount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: abi.encodePacked(
                bytes1(0xe1),
                bytes32(exclusiveFor),
                bytes4(uint32(startTime)),
                bytes4(uint32(stopTime)),
                bytes32(uint256(slope))
            )
        });

        bytes memory outputBytes = abi.encodePacked(
            outputs[0].oracle,
            outputs[0].settler,
            outputs[0].chainId,
            outputs[0].token,
            outputs[0].amount,
            outputs[0].recipient,
            uint16(outputs[0].call.length), // To protect against data collisions
            outputs[0].call,
            uint16(outputs[0].context.length), // To protect against data collisions
            outputs[0].context
        );

        bytes memory fillerData = abi.encodePacked(solverIdentifier);

        vm.prank(sender);
        if (startTime > currentTime) vm.expectRevert(abi.encodeWithSignature("ExclusiveTo(bytes32)", exclusiveFor));
        //outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], solverIdentifier);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
    }

    // --- FAILURE CASES --- //

    function test_fill_zero_filler(address sender, bytes32 orderId) public {
        bytes32[] memory orderIds = new bytes32[](1);
        MandateOutput[] memory outputs = new MandateOutput[](1);
        bytes32 filler = bytes32(0);

        orderIds[0] = orderId;
        outputs[0] = MandateOutput({
            settler: bytes32(0),
            oracle: bytes32(0),
            chainId: 0,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            call: bytes(""),
            context: bytes("")
        });

        bytes memory outputBytes = abi.encodePacked(
            outputs[0].oracle,
            outputs[0].settler,
            outputs[0].chainId,
            outputs[0].token,
            outputs[0].amount,
            outputs[0].recipient,
            uint16(outputs[0].call.length), // To protect against data collisions
            outputs[0].call,
            uint16(outputs[0].context.length), // To protect against data collisions
            outputs[0].context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(ZeroValue.selector);
        vm.prank(sender);
        //outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], filler);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
    }

    function test_invalid_chain_id(address sender, bytes32 filler, bytes32 orderId, uint256 chainId) public {
        vm.assume(chainId != block.chainid);
        vm.assume(filler != bytes32(0));

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            settler: bytes32(0),
            oracle: bytes32(0),
            chainId: chainId,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            call: bytes(""),
            context: bytes("")
        });

        bytes memory outputBytes = abi.encodePacked(
            outputs[0].oracle,
            outputs[0].settler,
            outputs[0].chainId,
            outputs[0].token,
            outputs[0].amount,
            outputs[0].recipient,
            uint16(outputs[0].call.length), // To protect against data collisions
            outputs[0].call,
            uint16(outputs[0].context.length), // To protect against data collisions
            outputs[0].context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, chainId, block.chainid));
        vm.prank(sender);
        //outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], filler);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
    }

    function test_invalid_filler(address sender, bytes32 filler, bytes32 orderId, bytes32 fillerOracleBytes) public {
        bytes32 outputSettlerCoinOracleBytes = bytes32(uint256(uint160(outputSettlerCoinAddress)));

        vm.assume(fillerOracleBytes != outputSettlerCoinOracleBytes);
        vm.assume(filler != bytes32(0));

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            settler: fillerOracleBytes,
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            call: bytes(""),
            context: bytes("")
        });

        bytes memory outputBytes = abi.encodePacked(
            outputs[0].oracle,
            outputs[0].settler,
            outputs[0].chainId,
            outputs[0].token,
            outputs[0].amount,
            outputs[0].recipient,
            uint16(outputs[0].call.length), // To protect against data collisions
            outputs[0].call,
            uint16(outputs[0].context.length), // To protect against data collisions
            outputs[0].context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(
            abi.encodeWithSelector(WrongOutputSettler.selector, outputSettlerCoinOracleBytes, fillerOracleBytes)
        );
        vm.prank(sender);
        //outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], filler);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
    }

    function test_revert_fill_deadline_passed(
        address sender,
        bytes32 filler,
        bytes32 orderId,
        uint32 fillDeadline,
        uint32 filledAt
    ) public {
        vm.assume(filler != bytes32(0));
        vm.assume(fillDeadline < filledAt);

        vm.warp(filledAt);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            call: bytes(""),
            context: bytes("")
        });

        bytes memory outputBytes = abi.encodePacked(
            outputs[0].oracle,
            outputs[0].settler,
            outputs[0].chainId,
            outputs[0].token,
            outputs[0].amount,
            outputs[0].recipient,
            uint16(outputs[0].call.length), // To protect against data collisions
            outputs[0].call,
            uint16(outputs[0].context.length), // To protect against data collisions
            outputs[0].context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.expectRevert(abi.encodeWithSignature("FillDeadline()"));
        vm.prank(sender);
        //outputSettlerCoin.fill(fillDeadline, orderId, outputs[0], filler);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
    }

    function test_fill_made_already(
        address sender,
        bytes32 filler,
        bytes32 differentFiller,
        bytes32 orderId,
        uint256 amount
    ) public {
        vm.assume(filler != bytes32(0));
        vm.assume(filler != differentFiller && differentFiller != bytes32(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);

        MandateOutput memory output = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(0),
            call: bytes(""),
            context: bytes("")
        });

        bytes memory outputBytes = abi.encodePacked(
            output.oracle,
            output.settler,
            output.chainId,
            output.token,
            output.amount,
            output.recipient,
            uint16(output.call.length), // To protect against data collisions
            output.call,
            uint16(output.context.length), // To protect against data collisions
            output.context
        );

        bytes memory fillerData = abi.encodePacked(filler);
        vm.prank(sender);
        //outputSettlerCoin.fill(type(uint32).max, orderId, output, filler);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
        bytes memory differentFillerData = abi.encodePacked(differentFiller);
        vm.prank(sender);
        //bytes32 alreadyFilledBy = outputSettlerCoin.fill(type(uint32).max, orderId, output, differentFiller);
        outputSettlerCoin.fill(orderId, outputBytes, differentFillerData);

        assertTrue(false);

        // assertNotEq(alreadyFilledBy, keccak256(abi.encodePacked(differentFiller, uint32(block.timestamp))));
        // assertEq(alreadyFilledBy, keccak256(abi.encodePacked(filler, uint32(block.timestamp))));
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
        vm.assume(filler != bytes32(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerCoinAddress, amount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(outputSettlerCoinAddress))),
            oracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: bytes(""),
            context: outputContext
        });

        bytes memory outputBytes = abi.encodePacked(
            outputs[0].oracle,
            outputs[0].settler,
            outputs[0].chainId,
            outputs[0].token,
            outputs[0].amount,
            outputs[0].recipient,
            uint16(outputs[0].call.length), // To protect against data collisions
            outputs[0].call,
            uint16(outputs[0].context.length), // To protect against data collisions
            outputs[0].context
        );

        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        vm.expectRevert(NotImplemented.selector);
        //outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], filler);
        outputSettlerCoin.fill(orderId, outputBytes, fillerData);
    }
}
