// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import { ERC7683EscrowAdapter } from "../../src/adapters/ERC7683Adapter.sol";

import {
    FillInstruction,
    GaslessCrossChainOrder,
    OnchainCrossChainOrder,
    Output,
    ResolvedCrossChainOrder
} from "../../src/interfaces/IERC7683.sol";

import { InputSettlerEscrow } from "../../src/input/escrow/InputSettlerEscrow.sol";
import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { StandardOrder } from "../../src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "../../src/interfaces/IInputSettlerEscrow.sol";

import { LibAddress } from "../../src/libs/LibAddress.sol";
import { InputSettlerEscrowTestBase } from "../input/escrow/InputSettlerEscrow.base.t.sol";

import { MandateOutputEncodingLib } from "../../src/libs/MandateOutputEncodingLib.sol";

contract ERC7683AdapterTest is InputSettlerEscrowTestBase {
    using LibAddress for address;
    using LibAddress for bytes32;

    ERC7683EscrowAdapter public adapter;
    // StandardOrder public order;
    // OnchainCrossChainOrder public onchainOrder;
    // GaslessCrossChainOrder public gaslessOrder;

    function setUp() public override {
        super.setUp();
        adapter = new ERC7683EscrowAdapter(InputSettlerEscrow(inputSettlerEscrow));
    }

    function test_open_gas() public {
        test_open(10000, 10 ** 18, makeAddr("user"));
    }

    function test_open(uint32 expires, uint128 amount, address user) public returns (StandardOrder memory) {
        vm.assume(expires < type(uint32).max);
        vm.assume(expires > block.timestamp);
        vm.assume(token.balanceOf(user) == 0);
        vm.assume(user != address(0) && user != inputSettlerEscrow);

        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(adapter), amount);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: expires,
            fillDeadline: expires,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        OnchainCrossChainOrder memory onchainOrder = OnchainCrossChainOrder({
            fillDeadline: expires,
            orderDataType: adapter.ONCHAIN_ORDER_DATA_TYPEHASH(),
            orderData: abi.encode(order)
        });

        assertEq(token.balanceOf(address(user)), amount);
        vm.expectCall(
            address(inputSettlerEscrow), abi.encodeWithSelector(IInputSettlerEscrow.open.selector, abi.encode(order))
        );
        vm.prank(user);
        adapter.open(onchainOrder);

        assertEq(token.balanceOf(address(user)), 0);
        assertEq(token.balanceOf(inputSettlerEscrow), amount);

        return order;
    }

    function test_open_orderDataType_reverts() public {
        OnchainCrossChainOrder memory onchainOrder;
        onchainOrder.orderDataType = adapter.GASLESS_ORDER_DATA_TYPEHASH();
        vm.expectRevert(abi.encodeWithSelector(ERC7683EscrowAdapter.InvalidOrderDataType.selector));
        adapter.open(onchainOrder);
    }

    function test_open_orderDeadline_reverts() public {
        StandardOrder memory order;
        OnchainCrossChainOrder memory onchainOrder;
        onchainOrder.orderDataType = adapter.ONCHAIN_ORDER_DATA_TYPEHASH();
        onchainOrder.orderData = abi.encode(order);
        onchainOrder.fillDeadline = uint32(1);
        vm.expectRevert(abi.encodeWithSelector(ERC7683EscrowAdapter.InvalidOrderDeadline.selector));
        adapter.open(onchainOrder);
    }

    /// forge-config: default.isolate = true
    function test_open_for_permit2_gas() external {
        test_open_for_permit2(10 ** 18, 251251);
    }

    function test_open_for_permit2(uint128 amountMint, uint256 nonce) public {
        token.mint(swapper, amountMint);
        uint256 amount = token.balanceOf(swapper);

        ERC7683EscrowAdapter.GaslessOrderData memory gaslessOrderData;

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        assertEq(token.balanceOf(address(swapper)), amount);

        gaslessOrderData = ERC7683EscrowAdapter.GaslessOrderData({
            expires: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });
        bytes memory signature = getPermit2Signature(swapperPrivateKey, order);

        GaslessCrossChainOrder memory gaslessOrder = GaslessCrossChainOrder({
            originSettler: address(adapter),
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            openDeadline: type(uint32).max,
            fillDeadline: type(uint32).max,
            orderDataType: adapter.GASLESS_ORDER_DATA_TYPEHASH(),
            orderData: abi.encode(gaslessOrderData)
        });

        vm.expectCall(
            address(inputSettlerEscrow),
            abi.encodeWithSelector(
                IInputSettlerEscrow.openFor.selector,
                abi.encode(order),
                swapper,
                abi.encodePacked(bytes1(0x00), signature)
            )
        );
        vm.prank(swapper);
        adapter.openFor(gaslessOrder, abi.encodePacked(bytes1(0x00), signature), bytes(""));

        assertEq(token.balanceOf(address(swapper)), 0);
        assertEq(token.balanceOf(inputSettlerEscrow), amount);
    }

    /// forge-config: default.isolate = true
    function test_open_for_3009_single() external {
        test_open_for_3009_single(10 ** 18, 251251);
    }

    function test_open_for_3009_single(uint128 amountMint, uint256 nonce) public {
        token.mint(swapper, amountMint);

        uint256 amount = token.balanceOf(swapper);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        ERC7683EscrowAdapter.GaslessOrderData memory gaslessOrderData = ERC7683EscrowAdapter.GaslessOrderData({
            expires: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        GaslessCrossChainOrder memory gaslessOrder = GaslessCrossChainOrder({
            originSettler: address(adapter),
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            openDeadline: type(uint32).max,
            fillDeadline: type(uint32).max,
            orderDataType: adapter.GASLESS_ORDER_DATA_TYPEHASH(),
            orderData: abi.encode(gaslessOrderData)
        });

        bytes memory signature = get3009Signature(swapperPrivateKey, inputSettlerEscrow, 0, order);

        assertEq(token.balanceOf(address(swapper)), amount);

        vm.expectCall(
            address(inputSettlerEscrow),
            abi.encodeWithSelector(
                IInputSettlerEscrow.openFor.selector,
                abi.encode(order),
                swapper,
                abi.encodePacked(bytes1(0x01), signature)
            )
        );
        vm.prank(swapper);
        adapter.openFor(gaslessOrder, abi.encodePacked(bytes1(0x01), signature), bytes(""));

        assertEq(token.balanceOf(address(swapper)), 0);
        assertEq(token.balanceOf(inputSettlerEscrow), amount);
    }

    /// forge-config: default.isolate = true
    function test_open_for_3009_single_as_array() external {
        test_open_for_3009_single_as_array(10 ** 18, 251251);
    }

    function test_open_for_3009_single_as_array(uint128 amountMint, uint256 nonce) public {
        token.mint(swapper, amountMint);

        uint256 amount = token.balanceOf(swapper);
        ERC7683EscrowAdapter.GaslessOrderData memory gaslessOrderData;

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        gaslessOrderData = ERC7683EscrowAdapter.GaslessOrderData({
            expires: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        GaslessCrossChainOrder memory gaslessOrder = GaslessCrossChainOrder({
            originSettler: address(adapter),
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            openDeadline: type(uint32).max,
            fillDeadline: type(uint32).max,
            orderDataType: adapter.GASLESS_ORDER_DATA_TYPEHASH(),
            orderData: abi.encode(gaslessOrderData)
        });

        bytes memory signature = get3009Signature(swapperPrivateKey, inputSettlerEscrow, 0, order);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;

        assertEq(token.balanceOf(address(swapper)), amount);
        vm.expectCall(
            address(inputSettlerEscrow),
            abi.encodeWithSelector(
                IInputSettlerEscrow.openFor.selector,
                abi.encode(order),
                swapper,
                abi.encodePacked(bytes1(0x01), abi.encode(signatures))
            )
        );
        vm.prank(swapper);
        adapter.openFor(gaslessOrder, abi.encodePacked(bytes1(0x01), abi.encode(signatures)), bytes(""));

        assertEq(token.balanceOf(address(swapper)), 0);
        assertEq(token.balanceOf(inputSettlerEscrow), amount);
    }

    /// forge-config: default.isolate = true
    function test_open_for_3009_two_as_array() external {
        test_open_for_3009_two_as_array(10 ** 18, 251251);
    }

    function test_open_for_3009_two_as_array(uint128 amountMint, uint256 nonce) public {
        token.mint(swapper, amountMint);
        anotherToken.mint(swapper, amountMint);

        uint256 amount1 = token.balanceOf(swapper);
        uint256 amount2 = anotherToken.balanceOf(swapper);
        ERC7683EscrowAdapter.GaslessOrderData memory gaslessOrderData;
        bytes[] memory signatures = new bytes[](2);

        uint256[2][] memory inputs = new uint256[2][](2);
        inputs[0] = [uint256(uint160(address(token))), amount1];
        inputs[1] = [uint256(uint160(address(anotherToken))), amount2];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        bytes memory signature1 = get3009Signature(swapperPrivateKey, inputSettlerEscrow, 0, order);
        bytes memory signature2 = get3009Signature(swapperPrivateKey, inputSettlerEscrow, 1, order);
        signatures[0] = signature1;
        signatures[1] = signature2;

        assertEq(token.balanceOf(address(swapper)), amount1);
        assertEq(anotherToken.balanceOf(address(swapper)), amount2);

        gaslessOrderData = ERC7683EscrowAdapter.GaslessOrderData({
            expires: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        GaslessCrossChainOrder memory gaslessOrder = GaslessCrossChainOrder({
            originSettler: address(adapter),
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            openDeadline: type(uint32).max,
            fillDeadline: type(uint32).max,
            orderDataType: adapter.GASLESS_ORDER_DATA_TYPEHASH(),
            orderData: abi.encode(gaslessOrderData)
        });

        vm.expectCall(
            address(inputSettlerEscrow),
            abi.encodeWithSelector(
                IInputSettlerEscrow.openFor.selector,
                abi.encode(order),
                swapper,
                abi.encodePacked(bytes1(0x01), abi.encode(signatures))
            )
        );
        vm.prank(swapper);
        adapter.openFor(gaslessOrder, abi.encodePacked(bytes1(0x01), abi.encode(signatures)), bytes(""));

        assertEq(token.balanceOf(address(swapper)), 0);
        assertEq(token.balanceOf(inputSettlerEscrow), amount1);
        assertEq(anotherToken.balanceOf(address(swapper)), 0);
        assertEq(anotherToken.balanceOf(inputSettlerEscrow), amount2);
    }

    function test_refund(uint32 expires, uint128 amount, address user) public {
        vm.assume(amount < type(uint128).max);
        StandardOrder memory order = test_open(expires, amount, user);
        // Wrap into the future of the expiry.
        vm.warp(order.expires + 1);

        bytes32 orderId = adapter.orderIdentifier(order);

        // Check order status:
        InputSettlerEscrow.OrderStatus status = adapter.orderStatus(orderId);
        assertEq(uint8(status), uint8(InputSettlerEscrow.OrderStatus.Deposited));

        // State
        uint256 amountBeforeRefund = token.balanceOf(address(order.user));

        vm.expectEmit();
        emit InputSettlerEscrow.Refunded(orderId);

        // Do the refund
        adapter.refund(order);

        // State
        assertEq(token.balanceOf(address(order.user)), amountBeforeRefund + amount);
        assertEq(token.balanceOf(inputSettlerEscrow), 0);

        status = adapter.orderStatus(orderId);
        assertEq(uint8(status), uint8(InputSettlerEscrow.OrderStatus.Refunded));
    }

    function test_open_for_fillerData_reverts() public {
        bytes memory notEmptyFillerData = bytes("not empty");
        GaslessCrossChainOrder memory gaslessOrder;

        vm.expectRevert(abi.encodeWithSelector(ERC7683EscrowAdapter.InvalidOriginFillerData.selector));
        adapter.openFor(gaslessOrder, abi.encodePacked(bytes1(0x01), bytes("")), notEmptyFillerData);
    }

    function test_open_for_orderDataType_reverts() public {
        GaslessCrossChainOrder memory gaslessOrder;
        vm.expectRevert(abi.encodeWithSelector(ERC7683EscrowAdapter.InvalidOrderDataType.selector));
        adapter.openFor(gaslessOrder, abi.encodePacked(bytes1(0x01), bytes("")), bytes(""));
    }

    function test_open_for_originSettler_reverts() public {
        GaslessCrossChainOrder memory gaslessOrder;
        gaslessOrder.orderDataType = adapter.GASLESS_ORDER_DATA_TYPEHASH();

        vm.expectRevert(abi.encodeWithSelector(ERC7683EscrowAdapter.InvalidOriginSettler.selector));
        adapter.openFor(gaslessOrder, abi.encodePacked(bytes1(0x01), bytes("")), bytes(""));
    }

    function test_resolve() public {
        uint256 amount = 10 ** 18;

        MandateOutput memory output = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = FillInstruction({
            destinationChainId: block.chainid,
            destinationSettler: address(outputSettlerCoin).toIdentifier(),
            originData: abi.encode(output)
        });

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: new MandateOutput[](1)
        });
        order.outputs[0] = output;
        OnchainCrossChainOrder memory onchainOrder;
        onchainOrder.fillDeadline = type(uint32).max;
        onchainOrder.orderDataType = adapter.ONCHAIN_ORDER_DATA_TYPEHASH();
        onchainOrder.orderData = abi.encode(order);

        Output[] memory expectedMaxSpent = new Output[](1);
        expectedMaxSpent[0] = Output({
            token: address(anotherToken).toIdentifier(),
            amount: type(uint256).max,
            recipient: swapper.toIdentifier(),
            chainId: block.chainid
        });

        Output[] memory expectedMinReceived = new Output[](1);
        expectedMinReceived[0] = Output({
            token: address(token).toIdentifier(),
            amount: amount,
            recipient: bytes32(0),
            chainId: block.chainid
        });

        ResolvedCrossChainOrder memory expectedResolvedOrder = ResolvedCrossChainOrder({
            user: swapper,
            originChainId: block.chainid,
            openDeadline: type(uint32).max,
            fillDeadline: type(uint32).max,
            orderId: adapter.orderIdentifier(order),
            maxSpent: expectedMaxSpent,
            minReceived: expectedMinReceived,
            fillInstructions: fillInstructions
        });

        ResolvedCrossChainOrder memory resolvedOrder = adapter.resolve(onchainOrder);
        assertEq(resolvedOrder.user, expectedResolvedOrder.user, "user mismatch");
        assertEq(resolvedOrder.originChainId, expectedResolvedOrder.originChainId, "origin chain id mismatch");
        assertEq(resolvedOrder.openDeadline, expectedResolvedOrder.openDeadline, "open deadline mismatch");
        assertEq(resolvedOrder.fillDeadline, expectedResolvedOrder.fillDeadline, "fill deadline mismatch");
        assertEq(resolvedOrder.orderId, expectedResolvedOrder.orderId, "order id mismatch");
        assertEq(resolvedOrder.maxSpent.length, expectedResolvedOrder.maxSpent.length, "max spent token mismatch");
        assertEq(resolvedOrder.maxSpent[0].token, expectedResolvedOrder.maxSpent[0].token, "max spent token mismatch");
        assertEq(
            resolvedOrder.maxSpent[0].amount, expectedResolvedOrder.maxSpent[0].amount, "max spent amount mismatch"
        );
        assertEq(
            resolvedOrder.maxSpent[0].recipient,
            expectedResolvedOrder.maxSpent[0].recipient,
            "max spent recipient mismatch"
        );
        assertEq(
            resolvedOrder.maxSpent[0].chainId, expectedResolvedOrder.maxSpent[0].chainId, "max spent chain id mismatch"
        );
        assertEq(resolvedOrder.minReceived.length, expectedResolvedOrder.minReceived.length, "min received mismatch");
        assertEq(
            resolvedOrder.minReceived[0].token,
            expectedResolvedOrder.minReceived[0].token,
            "min received token mismatch"
        );
    }

    function test_resolve_for() public {
        uint256 amount = 10 ** 18;
        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        MandateOutput memory output = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        fillInstructions[0] = FillInstruction({
            destinationChainId: block.chainid,
            destinationSettler: address(outputSettlerCoin).toIdentifier(),
            originData: abi.encode(output)
        });

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: new MandateOutput[](1)
        });
        order.outputs[0] = output;
        GaslessCrossChainOrder memory gaslessOrder;
        gaslessOrder.user = swapper;
        gaslessOrder.nonce = 0;
        gaslessOrder.originChainId = block.chainid;
        gaslessOrder.openDeadline = type(uint32).max;
        gaslessOrder.fillDeadline = type(uint32).max;
        ERC7683EscrowAdapter.GaslessOrderData memory gaslessOrderData = ERC7683EscrowAdapter.GaslessOrderData({
            expires: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: new MandateOutput[](1)
        });
        gaslessOrderData.outputs[0] = output;
        gaslessOrder.orderDataType = adapter.GASLESS_ORDER_DATA_TYPEHASH();
        gaslessOrder.orderData = abi.encode(gaslessOrderData);

        Output[] memory expectedMaxSpent = new Output[](1);
        expectedMaxSpent[0] = Output({
            token: address(anotherToken).toIdentifier(),
            amount: type(uint256).max,
            recipient: swapper.toIdentifier(),
            chainId: block.chainid
        });

        Output[] memory expectedMinReceived = new Output[](1);
        expectedMinReceived[0] = Output({
            token: address(token).toIdentifier(),
            amount: amount,
            recipient: bytes32(0),
            chainId: block.chainid
        });

        ResolvedCrossChainOrder memory expectedResolvedOrder = ResolvedCrossChainOrder({
            user: swapper,
            originChainId: block.chainid,
            openDeadline: type(uint32).max,
            fillDeadline: type(uint32).max,
            orderId: adapter.orderIdentifier(order),
            maxSpent: expectedMaxSpent,
            minReceived: expectedMinReceived,
            fillInstructions: fillInstructions
        });

        // bytes memory signature = getPermit2Signature(swapperPrivateKey, order);

        ResolvedCrossChainOrder memory resolvedOrder = adapter.resolveFor(gaslessOrder, bytes(""));
        assertEq(resolvedOrder.user, expectedResolvedOrder.user, "user mismatch");
        assertEq(resolvedOrder.originChainId, expectedResolvedOrder.originChainId, "origin chain id mismatch");
        assertEq(resolvedOrder.openDeadline, expectedResolvedOrder.openDeadline, "open deadline mismatch");
        assertEq(resolvedOrder.fillDeadline, expectedResolvedOrder.fillDeadline, "fill deadline mismatch");
        assertEq(resolvedOrder.orderId, expectedResolvedOrder.orderId, "order id mismatch");
        assertEq(resolvedOrder.maxSpent.length, expectedResolvedOrder.maxSpent.length, "max spent token mismatch");
    }

    /// forge-config: default.isolate = true
    function test_finalise_gas() public {
        test_finalise(makeAddr("non_solver"));
    }

    function test_finalise(
        address non_solver
    ) public {
        vm.assume(non_solver != solver);

        uint256 amount = 1e18 / 10;

        MandateOutput memory output = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: new MandateOutput[](1)
        });
        order.outputs[0] = output;
        OnchainCrossChainOrder memory onchainOrder;
        onchainOrder = OnchainCrossChainOrder({
            fillDeadline: type(uint32).max,
            orderDataType: adapter.ONCHAIN_ORDER_DATA_TYPEHASH(),
            orderData: abi.encode(order)
        });

        // Deposit into the escrow
        vm.prank(swapper);
        token.approve(address(adapter), amount);
        vm.expectCall(
            address(inputSettlerEscrow), abi.encodeWithSelector(IInputSettlerEscrow.open.selector, abi.encode(order))
        );
        vm.prank(swapper);
        adapter.open(onchainOrder);

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = solver.toIdentifier();

        // Other callers are disallowed:
        vm.prank(non_solver);

        vm.expectRevert(abi.encodeWithSignature("NotOrderOwner()"));
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, timestamps, solvers, solver.toIdentifier(), hex"");

        assertEq(token.balanceOf(solver), 0);

        bytes32 orderId = adapter.orderIdentifier(order);
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solver.toIdentifier(), orderId, uint32(block.timestamp), output
        );
        bytes32 payloadHash = keccak256(payload);

        vm.expectCall(
            address(alwaysYesOracle),
            abi.encodeWithSignature(
                "efficientRequireProven(bytes)",
                abi.encodePacked(
                    order.outputs[0].chainId, order.outputs[0].oracle, order.outputs[0].settler, payloadHash
                )
            )
        );

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, timestamps, solvers, solver.toIdentifier(), hex"");

        assertEq(token.balanceOf(solver), amount);
    }

    function test_revert_finalise_self_too_late(address non_solver, uint32 fillDeadline, uint32 filledAt) external {
        vm.assume(non_solver != solver);
        vm.assume(fillDeadline < filledAt);
        vm.assume(block.timestamp < fillDeadline);

        uint256 amount = 1e18 / 10;

        MandateOutput memory output = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: fillDeadline,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: new MandateOutput[](1)
        });
        order.outputs[0] = output;

        OnchainCrossChainOrder memory onchainOrder = OnchainCrossChainOrder({
            fillDeadline: fillDeadline,
            orderDataType: adapter.ONCHAIN_ORDER_DATA_TYPEHASH(),
            orderData: abi.encode(order)
        });

        // Deposit into the escrow
        vm.prank(swapper);
        token.approve(address(adapter), amount);
        vm.expectCall(
            address(inputSettlerEscrow), abi.encodeWithSelector(IInputSettlerEscrow.open.selector, abi.encode(order))
        );
        vm.prank(swapper);
        adapter.open(onchainOrder);

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = filledAt;

        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = solver.toIdentifier();

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("FilledTooLate(uint32,uint32)", fillDeadline, filledAt));
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, timestamps, solvers, solver.toIdentifier(), hex"");
    }

    /// forge-config: default.isolate = true
    function test_finalise_signature_gas() external {
        test_finalise_signature(makeAddr("destination"));
    }

    function test_finalise_signature(
        address destination
    ) public {
        vm.assume(destination != address(0));
        vm.assume(token.balanceOf(destination) == 0);

        uint256 amount = 1e18 / 10;

        MandateOutput memory output = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: new MandateOutput[](1)
        });
        order.outputs[0] = output;

        OnchainCrossChainOrder memory onchainOrder = OnchainCrossChainOrder({
            fillDeadline: type(uint32).max,
            orderDataType: adapter.ONCHAIN_ORDER_DATA_TYPEHASH(),
            orderData: abi.encode(order)
        });

        // Deposit into the escrow
        vm.prank(swapper);
        token.approve(address(adapter), amount);
        vm.expectCall(
            address(inputSettlerEscrow), abi.encodeWithSelector(IInputSettlerEscrow.open.selector, abi.encode(order))
        );
        vm.prank(swapper);
        adapter.open(onchainOrder);

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        bytes32 orderId = adapter.orderIdentifier(order);
        {
            bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solver.toIdentifier(), orderId, uint32(block.timestamp), output
            );
            bytes32 payloadHash = keccak256(payload);

            vm.expectCall(
                address(alwaysYesOracle),
                abi.encodeWithSignature(
                    "efficientRequireProven(bytes)",
                    abi.encodePacked(
                        order.outputs[0].chainId, order.outputs[0].oracle, order.outputs[0].settler, payloadHash
                    )
                )
            );
        }

        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = solver.toIdentifier();

        bytes memory orderOwnerSignature =
            this.getOrderOpenSignature(solverPrivateKey, orderId, destination.toIdentifier(), hex"");

        IInputSettlerEscrow(inputSettlerEscrow).finaliseWithSignature(
            order, timestamps, solvers, destination.toIdentifier(), hex"", orderOwnerSignature
        );

        assertEq(token.balanceOf(destination), amount);
    }
}
