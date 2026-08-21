// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { InputSettlerBase } from "../../src/input/InputSettlerBase.sol";
import { InputSettlerEscrow } from "../../src/input/escrow/InputSettlerEscrow.sol";
import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { StandardOrder } from "../../src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "../../src/interfaces/IInputSettlerEscrow.sol";

import { OutputSettlerSimple } from "../../src/output/simple/OutputSettlerSimple.sol";

import { WormholeOracle } from "../../src/integrations/oracles/wormhole/WormholeOracle.sol";
import { Messages } from "../../src/integrations/oracles/wormhole/external/wormhole/Messages.sol";
import { Setters } from "../../src/integrations/oracles/wormhole/external/wormhole/Setters.sol";
import { Structs } from "../../src/integrations/oracles/wormhole/external/wormhole/Structs.sol";

import { LibAddress } from "../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../src/libs/MessageEncodingLib.sol";

import { AlwaysYesOracle } from "../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

event PackagePublished(uint32 nonce, bytes payload, uint8 consistencyLevel);

/// @notice Mock Wormhole message contract for testing
contract ExportedMessages is Messages, Setters {
    function storeGuardianSetPub(
        Structs.GuardianSet memory set,
        uint32 index
    ) public {
        return super.storeGuardianSet(set, index);
    }

    function publishMessage(
        uint32 nonce,
        bytes calldata payload,
        uint8 consistencyLevel
    ) external payable returns (uint64) {
        emit PackagePublished(nonce, payload, consistencyLevel);
        return 0;
    }
}

/// @title InputSettlerEscrow Cross-Chain Integration Test
/// @notice Tests the complete flow of escrow-based input settlement with cross-chain outputs
contract InputSettlerEscrowTestCrossChain is Test {
    using LibAddress for address;

    uint128 constant DEFAULT_AMOUNT = 1e18;
    uint32 constant ONE_DAY = 1 days;

    // ============ Core Contracts ============

    address inputSettlerEscrow;
    OutputSettlerSimple outputSettlerSimple;

    // ============ Oracles ============

    address alwaysYesOracle;
    ExportedMessages messages;
    WormholeOracle wormholeOracle;

    // ============ Test Actors ============

    uint256 swapperPrivateKey;
    address swapper;
    uint256 solverPrivateKey;
    address solver;
    uint256 testGuardianPrivateKey;
    address testGuardian;

    // ============ Mock Tokens ============

    MockERC20 token;
    MockERC20 anotherToken;

    // ============ Setup ============

    function setUp() public virtual {
        // Deploy core contracts
        inputSettlerEscrow = address(new InputSettlerEscrow());
        outputSettlerSimple = new OutputSettlerSimple();

        // Deploy and setup oracles
        alwaysYesOracle = address(new AlwaysYesOracle());
        _setupWormholeOracle();

        // Create test actors
        (swapper, swapperPrivateKey) = makeAddrAndKey("swapper");
        (solver, solverPrivateKey) = makeAddrAndKey("solver");

        // Deploy mock tokens
        token = new MockERC20("Token", "TOKEN", 18);
        anotherToken = new MockERC20("Another Token", "ANOTHERTOKEN", 18);

        // Mint initial balances
        token.mint(swapper, DEFAULT_AMOUNT);
        anotherToken.mint(solver, DEFAULT_AMOUNT);

        // Approve tokens for inputSettlerEscrow
        vm.prank(swapper);
        token.approve(inputSettlerEscrow, DEFAULT_AMOUNT);

        // Approve tokens for outputSettlerSimple
        vm.startPrank(solver);
        token.approve(address(outputSettlerSimple), type(uint256).max);
        anotherToken.approve(address(outputSettlerSimple), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    /// @notice Setup Wormhole oracle with guardian set
    function _setupWormholeOracle() private {
        messages = new ExportedMessages();
        address wormholeDeployment = makeAddr("wormholeOracle");
        deployCodeTo("WormholeOracle.sol", abi.encode(address(this), address(messages)), wormholeDeployment);
        wormholeOracle = WormholeOracle(wormholeDeployment);

        wormholeOracle.setChainMap(uint16(block.chainid), block.chainid);

        (testGuardian, testGuardianPrivateKey) = makeAddrAndKey("testGuardian");

        // Initialize guardian set with one guardian
        address[] memory keys = new address[](1);
        keys[0] = testGuardian;
        Structs.GuardianSet memory guardianSet = Structs.GuardianSet(keys, 0);
        require(messages.quorum(guardianSet.keys.length) == 1, "Quorum should be 1");

        messages.storeGuardianSetPub(guardianSet, uint32(0));
    }

    /// @notice Encode message for oracle submission
    function encodeMessage(
        bytes32 remoteIdentifier,
        bytes[] calldata payloads
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(remoteIdentifier, payloads);
    }

    /// @notice Create a valid Wormhole VAA for testing
    function _makeValidVAA(
        uint16 emitterChainId,
        bytes32 emitterAddress,
        bytes memory message
    ) internal view returns (bytes memory validVM) {
        bytes memory preMessage = abi.encodePacked(
            hex"000003e8" hex"00000001", emitterChainId, emitterAddress, hex"0000000000000539" hex"0f"
        );
        bytes memory postvalidVM = abi.encodePacked(preMessage, message);
        bytes32 vmHash = keccak256(abi.encodePacked(keccak256(postvalidVM)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testGuardianPrivateKey, vmHash);

        validVM = abi.encodePacked(hex"01" hex"00000000" hex"01", uint8(0), r, s, v - 27, postvalidVM);
    }

    /// @notice Create a standard order with default parameters
    function _createOrder(
        address oracle,
        uint128 amount,
        uint32 expires
    ) internal view returns (StandardOrder memory order) {
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerSimple).toIdentifier(),
            oracle: oracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
            context: hex""
        });

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: expires,
            fillDeadline: expires,
            inputOracle: oracle,
            inputs: inputs,
            outputs: outputs
        });
    }

    function _createSolveParams(
        bytes32 solverIdentifier
    ) internal view returns (InputSettlerBase.SolveParams[] memory solveParams) {
        solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solverIdentifier, timestamp: uint32(block.timestamp) });
    }

    // ============ Test Cases ============

    /// @notice Test opening an escrow order
    function test_open() public returns (StandardOrder memory order) {
        uint32 expires = uint32(block.timestamp + ONE_DAY);

        // Approve and create order
        order = _createOrder(alwaysYesOracle, DEFAULT_AMOUNT, expires);

        // Verify initial balances
        assertEq(token.balanceOf(address(swapper)), DEFAULT_AMOUNT);

        // Open escrow
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);

        // Verify balances after opening
        assertEq(token.balanceOf(address(swapper)), 0);
        assertEq(token.balanceOf(inputSettlerEscrow), DEFAULT_AMOUNT);

        return order;
    }

    /// @notice Test opening and refunding an expired order
    function test_open_and_refund() external {
        StandardOrder memory order = test_open();

        // Fast forward past expiry
        vm.warp(order.expires + 1);

        bytes32 orderId = InputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);

        // Verify order is in Deposited state
        InputSettlerEscrow.OrderStatus status = InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId);

        assertEq(uint8(status), uint8(InputSettlerEscrow.OrderStatus.Deposited), "Order should be deposited");

        uint256 amountBeforeRefund = token.balanceOf(address(order.user));

        // Refund the order
        vm.expectEmit();
        emit InputSettlerEscrow.Refunded(orderId);

        InputSettlerEscrow(inputSettlerEscrow).refund(order);

        // Verify balances after refund
        assertEq(
            token.balanceOf(address(order.user)), amountBeforeRefund + order.inputs[0][1], "User should receive refund"
        );
        assertEq(token.balanceOf(inputSettlerEscrow), 0);

        // Verify order status
        status = InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId);
        assertEq(uint8(status), uint8(InputSettlerEscrow.OrderStatus.Refunded));
    }

    /// @notice Test opening and finalizing an order with proof validation
    function test_open_and_finalise() public {
        StandardOrder memory order = test_open();

        // Setup solve parameters
        InputSettlerBase.SolveParams[] memory solveParams = _createSolveParams(solver.toIdentifier());

        uint256 amountBeforeFinalise = token.balanceOf(solver);
        assertEq(amountBeforeFinalise, 0);

        // Create proof payload
        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solver.toIdentifier(), orderId, uint32(block.timestamp), order.outputs[0]
        );
        bytes32 payloadHash = keccak256(payload);

        // Expect oracle proof validation call
        vm.expectCall(
            address(alwaysYesOracle),
            abi.encodeWithSignature(
                "efficientRequireProven(bytes)",
                abi.encodePacked(
                    order.outputs[0].chainId, order.outputs[0].oracle, order.outputs[0].settler, payloadHash
                )
            )
        );

        // Finalize the order
        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, solveParams, solver.toIdentifier(), hex"");

        // Verify solver received payment
        assertEq(token.balanceOf(solver), amountBeforeFinalise + order.inputs[0][1]);
    }

    /// @notice Test complete end-to-end flow: open → fill → submit proof → finalize
    function test_entire_flow() external {
        uint32 expires = uint32(block.timestamp + ONE_DAY);

        // Step 1: Open escrow order
        StandardOrder memory order = _createOrder(address(wormholeOracle), DEFAULT_AMOUNT, expires);

        assertEq(token.balanceOf(address(swapper)), DEFAULT_AMOUNT);

        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);

        // Step 2: Solver fills output on destination chain
        bytes32 solverIdentifier = solver.toIdentifier();
        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        bytes memory fillerData = abi.encodePacked(solverIdentifier);

        vm.prank(solver);
        outputSettlerSimple.fill(orderId, order.outputs[0], expires, fillerData);

        // Step 3: Submit proof to Wormhole oracle
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solverIdentifier,
            orderId,
            uint32(block.timestamp),
            address(anotherToken).toIdentifier(),
            DEFAULT_AMOUNT,
            swapper.toIdentifier(),
            hex"",
            hex""
        );

        bytes memory expectedMessageEmitted = this.encodeMessage(address(outputSettlerSimple).toIdentifier(), payloads);

        vm.expectEmit();
        emit PackagePublished(0, expectedMessageEmitted, 15);
        wormholeOracle.submit(address(outputSettlerSimple), payloads);

        // Step 4: Receive proof via Wormhole VAA
        bytes memory vaa =
            _makeValidVAA(uint16(block.chainid), address(wormholeOracle).toIdentifier(), expectedMessageEmitted);

        wormholeOracle.receiveMessage(vaa);

        // Step 5: Finalize order and pay solver
        InputSettlerBase.SolveParams[] memory solveParams = _createSolveParams(solver.toIdentifier());

        uint256 amountBeforeFinalise = token.balanceOf(solver);
        assertEq(amountBeforeFinalise, 0);

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, solveParams, solver.toIdentifier(), hex"");

        // Verify solver received payment
        assertEq(token.balanceOf(solver), amountBeforeFinalise + order.inputs[0][1]);
    }
}
