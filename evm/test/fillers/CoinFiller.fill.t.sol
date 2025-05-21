// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { CoinFiller } from "src/fillers/coin/CoinFiller.sol";
import { MandateOutput } from "src/libs/MandateOutputEncodingLib.sol";

import { MockCallbackExecutor } from "test/mocks/MockCallbackExecutor.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

contract CoinFillerTestFill is Test {
    error ZeroValue();
    error WrongChain(uint256 expected, uint256 actual);
    error WrongRemoteFiller(bytes32 addressThis, bytes32 expected);
    error NotImplemented();
    error SlopeStopped();

    event OutputFilled(bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output);

    CoinFiller coinFiller;

    MockERC20 outputToken;
    MockCallbackExecutor mockCallbackExecutor;

    address swapper;
    address coinFillerAddress;
    address outputTokenAddress;
    address mockCallbackExecutorAddress;

    function setUp() public {
        coinFiller = new CoinFiller();
        outputToken = new MockERC20("TEST", "TEST", 18);
        mockCallbackExecutor = new MockCallbackExecutor();

        swapper = makeAddr("swapper");
        coinFillerAddress = address(coinFiller);
        outputTokenAddress = address(outputToken);
        mockCallbackExecutorAddress = address(mockCallbackExecutor);
    }

    // --- VALID CASES --- //

    /// forge-config: default.isolate = true
    function test_fill_gas() external {
        test_fill(keccak256(bytes("orderId")), makeAddr("sender"), keccak256(bytes("filler")), 10 ** 18);
    }

    function test_fill(bytes32 orderId, address sender, bytes32 filler, uint256 amount) public {
        vm.assume(filler != bytes32(0) && swapper != sender);

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(coinFillerAddress, amount);

        MandateOutput memory output = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(coinFillerAddress))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            remoteCall: bytes(""),
            fulfillmentContext: bytes("")
        });

        vm.prank(sender);
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), output);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, amount)
        );

        coinFiller.fill(type(uint32).max, orderId, output, filler);
        vm.snapshotGasLastCall("filler", "coinFillerFill");

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
        vm.assume(solverIdentifier != bytes32(0) && swapper != sender);
        vm.warp(currentTime);

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(coinFillerAddress, amount);

        MandateOutput memory output = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(coinFillerAddress))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            remoteCall: bytes(""),
            fulfillmentContext: abi.encodePacked(bytes1(0xe0), exclusiveFor, startTime)
        });

        vm.prank(sender);

        if (exclusiveFor != solverIdentifier && currentTime < startTime) {
            vm.expectRevert(abi.encodeWithSignature("ExclusiveTo(bytes32)", exclusiveFor));
        }
        coinFiller.fill(type(uint32).max, orderId, output, solverIdentifier);
        vm.snapshotGasLastCall("filler", "coinFillerFillExclusive");
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
        outputToken.approve(coinFillerAddress, amount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(coinFillerAddress))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(mockCallbackExecutorAddress))),
            remoteCall: remoteCallData,
            fulfillmentContext: bytes("")
        });

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

        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputs[0]);

        coinFiller.fill(type(uint32).max, orderId, outputs[0], filler);

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
        outputToken.approve(coinFillerAddress, finalAmount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(coinFillerAddress))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            remoteCall: bytes(""),
            fulfillmentContext: abi.encodePacked(
                bytes1(0x01), bytes4(uint32(startTime)), bytes4(uint32(stopTime)), bytes32(uint256(slope))
            )
        });

        vm.prank(sender);

        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), outputs[0]);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, finalAmount)
        );
        coinFiller.fill(type(uint32).max, orderId, outputs[0], filler);
        vm.snapshotGasLastCall("filler", "coinFillerFillDutchAuction");

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
        outputToken.approve(coinFillerAddress, finalAmount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(coinFillerAddress))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            remoteCall: bytes(""),
            fulfillmentContext: abi.encodePacked(
                bytes1(0xe1),
                bytes32(exclusiveFor),
                bytes4(uint32(startTime)),
                bytes4(uint32(stopTime)),
                bytes32(uint256(slope))
            )
        });

        vm.prank(sender);

        vm.expectEmit();
        emit OutputFilled(orderId, exclusiveFor, uint32(block.timestamp), outputs[0]);

        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, swapper, finalAmount)
        );

        coinFiller.fill(type(uint32).max, orderId, outputs[0], exclusiveFor);
        vm.snapshotGasLastCall("filler", "coinFillerFillExclusiveDutchAuction");

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
        outputToken.approve(coinFillerAddress, finalAmount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(coinFillerAddress))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            remoteCall: bytes(""),
            fulfillmentContext: abi.encodePacked(
                bytes1(0xe1),
                bytes32(exclusiveFor),
                bytes4(uint32(startTime)),
                bytes4(uint32(stopTime)),
                bytes32(uint256(slope))
            )
        });

        vm.prank(sender);
        if (startTime > currentTime) vm.expectRevert(abi.encodeWithSignature("ExclusiveTo(bytes32)", exclusiveFor));
        coinFiller.fill(type(uint32).max, orderId, outputs[0], solverIdentifier);
    }

    // --- FAILURE CASES --- //

    function test_fill_zero_filler(address sender, bytes32 orderId) public {
        bytes32[] memory orderIds = new bytes32[](1);
        MandateOutput[] memory outputs = new MandateOutput[](1);
        bytes32 filler = bytes32(0);

        orderIds[0] = orderId;
        outputs[0] = MandateOutput({
            remoteFiller: bytes32(0),
            remoteOracle: bytes32(0),
            chainId: 0,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            remoteCall: bytes(""),
            fulfillmentContext: bytes("")
        });

        vm.expectRevert(ZeroValue.selector);
        vm.prank(sender);
        coinFiller.fill(type(uint32).max, orderId, outputs[0], filler);
    }

    function test_invalid_chain_id(address sender, bytes32 filler, bytes32 orderId, uint256 chainId) public {
        vm.assume(chainId != block.chainid);
        vm.assume(filler != bytes32(0));

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            remoteFiller: bytes32(0),
            remoteOracle: bytes32(0),
            chainId: chainId,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            remoteCall: bytes(""),
            fulfillmentContext: bytes("")
        });

        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, chainId, block.chainid));
        vm.prank(sender);
        coinFiller.fill(type(uint32).max, orderId, outputs[0], filler);
    }

    function test_invalid_filler(address sender, bytes32 filler, bytes32 orderId, bytes32 fillerOracleBytes) public {
        bytes32 coinFillerOracleBytes = bytes32(uint256(uint160(coinFillerAddress)));

        vm.assume(fillerOracleBytes != coinFillerOracleBytes);
        vm.assume(filler != bytes32(0));

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            remoteFiller: fillerOracleBytes,
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            remoteCall: bytes(""),
            fulfillmentContext: bytes("")
        });

        vm.expectRevert(abi.encodeWithSelector(WrongRemoteFiller.selector, coinFillerOracleBytes, fillerOracleBytes));
        vm.prank(sender);
        coinFiller.fill(type(uint32).max, orderId, outputs[0], filler);
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
            remoteFiller: bytes32(uint256(uint160(coinFillerAddress))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(0),
            amount: 0,
            recipient: bytes32(0),
            remoteCall: bytes(""),
            fulfillmentContext: bytes("")
        });

        vm.expectRevert(abi.encodeWithSignature("FillDeadline()"));
        vm.prank(sender);
        coinFiller.fill(fillDeadline, orderId, outputs[0], filler);
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
        outputToken.approve(coinFillerAddress, amount);

        MandateOutput memory output = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(coinFillerAddress))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(0),
            remoteCall: bytes(""),
            fulfillmentContext: bytes("")
        });

        vm.prank(sender);
        coinFiller.fill(type(uint32).max, orderId, output, filler);
        vm.prank(sender);
        bytes32 alreadyFilledBy = coinFiller.fill(type(uint32).max, orderId, output, differentFiller);

        assertNotEq(alreadyFilledBy, differentFiller);
        assertEq(alreadyFilledBy, filler);
    }

    function test_invalid_fulfillment_context(
        address sender,
        bytes32 filler,
        bytes32 orderId,
        uint256 amount,
        bytes memory fulfillmentContext
    ) public {
        vm.assume(bytes1(fulfillmentContext) != 0x00 && fulfillmentContext.length != 1);
        vm.assume(bytes1(fulfillmentContext) != 0x01 && fulfillmentContext.length != 41);
        vm.assume(bytes1(fulfillmentContext) != 0xe0 && fulfillmentContext.length != 37);
        vm.assume(bytes1(fulfillmentContext) != 0xe1 && fulfillmentContext.length != 73);
        vm.assume(filler != bytes32(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(coinFillerAddress, amount);

        MandateOutput[] memory outputs = new MandateOutput[](1);

        outputs[0] = MandateOutput({
            remoteFiller: bytes32(uint256(uint160(coinFillerAddress))),
            remoteOracle: bytes32(0),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            remoteCall: bytes(""),
            fulfillmentContext: fulfillmentContext
        });

        vm.prank(sender);
        vm.expectRevert(NotImplemented.selector);
        coinFiller.fill(type(uint32).max, orderId, outputs[0], filler);
    }
}
