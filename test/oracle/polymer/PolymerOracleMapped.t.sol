// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "src/input/types/MandateOutputType.sol";
import { PolymerOracle } from "src/integrations/oracles/polymer/PolymerOracle.sol";
import { PolymerOracleMapped } from "src/integrations/oracles/polymer/PolymerOracleMapped.sol";
import { MockCrossL2ProverV2 } from "src/integrations/oracles/polymer/external/mocks/MockCrossL2ProverV2.sol";
import { LibAddress } from "src/libs/LibAddress.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { InputSettlerBase } from "src/input/InputSettlerBase.sol";
import { InputSettlerEscrow } from "src/input/escrow/InputSettlerEscrow.sol";
import { StandardOrder } from "src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "src/interfaces/IInputSettlerEscrow.sol";
import { MandateOutputEncodingLib } from "src/libs/MandateOutputEncodingLib.sol";
import { OutputSettlerBase } from "src/output/OutputSettlerBase.sol";
import { OutputSettlerSimple } from "src/output/simple/OutputSettlerSimple.sol";

contract PolymerOracleMappedTest is Test {
    using LibAddress for address;

    event OutputProven(uint256 chainid, bytes32 remoteIdentifier, bytes32 application, bytes32 payloadHash);

    MockCrossL2ProverV2 mockCrossL2ProverV2;
    PolymerOracleMapped polymerOracleMapped;

    string clientType = "mock-proof";
    address sequencer = vm.addr(uint256(keccak256("sequencer")));
    bytes32 peptideChainId = keccak256("peptide");

    address inputSettlerEscrow;
    MockERC20 token;
    MockERC20 anotherToken;
    address swapper;
    address solver;
    OutputSettlerSimple outputSettler;

    address owner;

    function setUp() public {
        owner = makeAddr("owner");
        mockCrossL2ProverV2 = new MockCrossL2ProverV2(clientType, sequencer, peptideChainId);
        polymerOracleMapped = new PolymerOracleMapped(owner, address(mockCrossL2ProverV2));

        inputSettlerEscrow = address(new InputSettlerEscrow());
        swapper = makeAddr("swapper");
        solver = makeAddr("solver");
        outputSettler = new OutputSettlerSimple();

        token = new MockERC20("Mock ERC20", "MOCK", 18);
        anotherToken = new MockERC20("Mock2 ERC20", "MOCK2", 18);
        token.mint(swapper, 1e18);
    }

    function test_mock_proof() public {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = keccak256("event");
        topics[1] = keccak256("data");

        bytes memory data = abi.encode("some data");

        vm.prank(owner);
        polymerOracleMapped.setChainMap(1, 1);

        bytes memory mockProof =
            mockCrossL2ProverV2.generateAndEmitProof(1, vm.addr(uint256(keccak256("emitter"))), topics, data);

        (uint32 chainId, address emittingContract, bytes memory emittedTopics, bytes memory unindexedData) =
            mockCrossL2ProverV2.validateEvent(mockProof);

        assertEq(chainId, 1);
        assertEq(emittingContract, vm.addr(uint256(keccak256("emitter"))));
        assertEq(emittedTopics, abi.encodePacked(topics[0], topics[1]));
        assertEq(unindexedData, abi.encode("some data"));
    }

    function test_receiveMessage_with_proof() public {
        bytes32 orderId = keccak256("orderId");
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputFilled.selector;
        topics[1] = orderId;

        MandateOutput memory mandateOutput = MandateOutput({
            oracle: makeAddr("oracle").toIdentifier(),
            settler: makeAddr("settler").toIdentifier(),
            chainId: 1,
            token: makeAddr("token").toIdentifier(),
            amount: 1000000000000000000,
            recipient: makeAddr("recipient").toIdentifier(),
            callbackData: bytes(""),
            context: bytes("")
        });

        uint32 timestamp = uint32(block.timestamp);
        bytes memory unindexedData = abi.encode(solver.toIdentifier(), timestamp, mandateOutput);

        uint32 remoteChainId = 1;

        vm.prank(owner);
        polymerOracleMapped.setChainMap(remoteChainId, remoteChainId);

        bytes memory mockProof =
            mockCrossL2ProverV2.generateAndEmitProof(remoteChainId, makeAddr("settler"), topics, unindexedData);

        bytes32 expectedPayloadHash = keccak256(
            MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solver.toIdentifier(), orderId, timestamp, mandateOutput
            )
        );

        vm.expectEmit();
        emit OutputProven(
            remoteChainId,
            address(polymerOracleMapped).toIdentifier(),
            makeAddr("settler").toIdentifier(),
            expectedPayloadHash
        );
        polymerOracleMapped.receiveMessage(mockProof);
    }

    function test_receiveMessage_multiple_proofs() public {
        bytes32 orderId1 = keccak256("orderId1");
        bytes32 orderId2 = keccak256("orderId2");
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputFilled.selector;
        topics[1] = orderId1;

        MandateOutput memory mandateOutput = MandateOutput({
            oracle: makeAddr("oracle").toIdentifier(),
            settler: makeAddr("settler").toIdentifier(),
            chainId: 1,
            token: makeAddr("token").toIdentifier(),
            amount: 1000000000000000000,
            recipient: makeAddr("recipient").toIdentifier(),
            callbackData: bytes(""),
            context: bytes("")
        });

        uint32 timestamp = uint32(block.timestamp);
        bytes memory unindexedData = abi.encode(solver.toIdentifier(), timestamp, mandateOutput);

        uint32 remoteChainId1 = 1;
        uint32 remoteChainId2 = 2;
        vm.prank(owner);
        polymerOracleMapped.setChainMap(remoteChainId1, remoteChainId1);
        vm.prank(owner);
        polymerOracleMapped.setChainMap(remoteChainId2, remoteChainId2);

        bytes memory mockProof1 =
            mockCrossL2ProverV2.generateAndEmitProof(remoteChainId1, makeAddr("settler"), topics, unindexedData);

        bytes32 expectedPayloadHash1 = keccak256(
            MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solver.toIdentifier(), orderId1, timestamp, mandateOutput
            )
        );

        topics[1] = orderId2;

        bytes memory mockProof2 =
            mockCrossL2ProverV2.generateAndEmitProof(remoteChainId2, makeAddr("settler"), topics, unindexedData);

        bytes32 expectedPayloadHash2 = keccak256(
            MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solver.toIdentifier(), orderId2, timestamp, mandateOutput
            )
        );

        vm.expectEmit();
        emit OutputProven(
            remoteChainId1,
            address(polymerOracleMapped).toIdentifier(),
            makeAddr("settler").toIdentifier(),
            expectedPayloadHash1
        );
        emit OutputProven(
            remoteChainId2,
            address(polymerOracleMapped).toIdentifier(),
            makeAddr("settler").toIdentifier(),
            expectedPayloadHash2
        );
        bytes[] memory proofs = new bytes[](2);
        proofs[0] = mockProof1;
        proofs[1] = mockProof2;
        polymerOracleMapped.receiveMessage(proofs);
    }

    function test_receiveMessage_wrong_event_signature() public {
        bytes32 orderId = keccak256("orderId");
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = keccak256("event");
        topics[1] = orderId;

        vm.prank(owner);
        polymerOracleMapped.setChainMap(1, 1);

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitProof(
            1, vm.addr(uint256(keccak256("emitter"))), topics, abi.encode("some data")
        );

        vm.expectRevert(PolymerOracle.WrongEventSignature.selector);
        polymerOracleMapped.receiveMessage(mockProof);
    }

    function test_receiveMessage_and_finalise() public {
        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettler).toIdentifier(),
            oracle: address(polymerOracleMapped).toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
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
            inputOracle: address(polymerOracleMapped),
            inputs: inputs,
            outputs: outputs
        });

        // Deposit into the escrow
        vm.prank(swapper);
        token.approve(inputSettlerEscrow, amount);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] =
            InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: uint32(block.timestamp) });

        assertEq(token.balanceOf(solver), 0);

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solver.toIdentifier(), orderId, uint32(block.timestamp), outputs[0]
        );
        bytes32 payloadHash = keccak256(payload);

        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputFilled.selector;
        topics[1] = orderId;

        uint32 timestamp = uint32(block.timestamp);
        bytes memory unindexedData = abi.encode(solver.toIdentifier(), timestamp, outputs[0]);
        vm.prank(owner);
        polymerOracleMapped.setChainMap(block.chainid, block.chainid);

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitProof(
            uint32(block.chainid), address(outputSettler), topics, unindexedData
        );

        vm.expectEmit();
        emit OutputProven(
            block.chainid,
            address(polymerOracleMapped).toIdentifier(),
            address(outputSettler).toIdentifier(),
            payloadHash
        );
        polymerOracleMapped.receiveMessage(mockProof);

        vm.expectCall(
            address(polymerOracleMapped),
            abi.encodeWithSignature(
                "efficientRequireProven(bytes)",
                abi.encodePacked(
                    order.outputs[0].chainId, order.outputs[0].oracle, order.outputs[0].settler, payloadHash
                )
            )
        );

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, solveParams, solver.toIdentifier(), hex"");

        assertEq(token.balanceOf(solver), amount);
    }
}
