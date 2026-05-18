// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";

import { LibAddress } from "../../src/libs/LibAddress.sol";
import { OutputSettlerBase } from "../../src/output/OutputSettlerBase.sol";
import { FillerDataLib } from "../../src/output/simple/FillerDataLib.sol";

import { InputSettlerBase } from "../../src/input/InputSettlerBase.sol";
import { InputSettlerEscrow } from "../../src/input/escrow/InputSettlerEscrow.sol";
import { StandardOrder } from "../../src/input/types/StandardOrderType.sol";
import { CatsMulticallHandler } from "../../src/integrations/CatsMulticallHandler.sol";

import { IInputSettlerEscrow } from "../../src/interfaces/IInputSettlerEscrow.sol";
import { MandateOutputEncodingLib } from "../../src/libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../../src/libs/OutputVerificationLib.sol";
import { AlwaysYesOracle } from "../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

contract OutputSettlerMock is OutputSettlerBase {
    using FillerDataLib for bytes;

    function _resolveOutput(
        MandateOutput calldata output,
        bytes calldata fillerData
    ) internal pure override returns (bytes32 solver, uint256 amount) {
        amount = output.amount;
        solver = fillerData.solver();
    }
}

contract FallbackRecipientMock {
    function mockCall() external { }
}

contract CatsMulticallHandlerTest is Test {
    using LibAddress for address;

    error ZeroValue();
    error WrongChain(uint256 expected, uint256 actual);
    error WrongOutputSettler(bytes32 addressThis, bytes32 expected);
    error NotImplemented();
    error SlopeStopped();

    event OutputFilled(
        bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output, uint256 finalAmount
    );

    OutputSettlerMock outputSettler;

    MockERC20 outputToken;
    CatsMulticallHandler multicallHandler;

    address swapper;
    address outputSettlerAddress;
    address outputTokenAddress;
    address multicallHandlerAddress;

    address fallbackRecipient;
    address fallbackRecipientWithCode;

    address solver;
    address alwaysYesOracle;

    MockERC20 token;
    MockERC20 anotherToken;

    address inputSettlerEscrow;

    function setUp() public {
        outputSettler = new OutputSettlerMock();
        outputToken = new MockERC20("TEST", "TEST", 18);
        multicallHandler = new CatsMulticallHandler();

        swapper = makeAddr("swapper");
        fallbackRecipient = makeAddr("fallbackRecipient");
        fallbackRecipientWithCode = address(new FallbackRecipientMock());
        outputSettlerAddress = address(outputSettler);
        outputTokenAddress = address(outputToken);
        multicallHandlerAddress = address(multicallHandler);

        solver = makeAddr("solver");
        alwaysYesOracle = address(new AlwaysYesOracle());
        inputSettlerEscrow = address(new InputSettlerEscrow());

        token = new MockERC20("Mock ERC20", "MOCK", 18);
        anotherToken = new MockERC20("Mock2 ERC20", "MOCK2", 18);
        token.mint(swapper, 1e18);
    }

    function test_fill_multicall_handler_simple() public {
        address sender = makeAddr("sender");
        bytes32 orderId = keccak256(bytes("orderId"));
        uint256 amount = 10 ** 18;
        bytes32 filler = keccak256(bytes("filler"));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerAddress, amount);

        CatsMulticallHandler.Call[] memory calls = new CatsMulticallHandler.Call[](0);

        CatsMulticallHandler.Instructions memory instructions = CatsMulticallHandler.Instructions({
            setApprovalsUsingInputsFor: address(0), calls: calls, fallbackRecipient: address(0)
        });

        bytes memory remoteCallData = abi.encode(instructions);
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(multicallHandlerAddress))),
            callbackData: remoteCallData,
            context: bytes("")
        });
        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        vm.expectCall(
            multicallHandlerAddress,
            abi.encodeWithSignature(
                "outputFilled(bytes32,uint256,bytes)",
                bytes32(uint256(uint160(outputTokenAddress))),
                amount,
                remoteCallData
            )
        );
        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, multicallHandlerAddress, amount)
        );
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), output, amount);
        outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        assertEq(outputToken.balanceOf(multicallHandlerAddress), amount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    function test_fill_multicall_handler_with_fallback_recipient() public {
        address sender = makeAddr("sender");
        bytes32 orderId = keccak256(bytes("orderId"));
        uint256 amount = 10 ** 18;
        bytes32 filler = keccak256(bytes("filler"));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerAddress, amount);

        CatsMulticallHandler.Call[] memory calls = new CatsMulticallHandler.Call[](1);

        calls[0] = CatsMulticallHandler.Call({
            target: fallbackRecipientWithCode, callData: abi.encodeWithSignature("mockCall()"), value: 0
        });

        CatsMulticallHandler.Instructions memory instructions = CatsMulticallHandler.Instructions({
            setApprovalsUsingInputsFor: fallbackRecipientWithCode,
            calls: calls,
            fallbackRecipient: fallbackRecipientWithCode
        });

        bytes memory remoteCallData = abi.encode(instructions);
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(multicallHandlerAddress))),
            callbackData: remoteCallData,
            context: bytes("")
        });
        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        vm.expectCall(
            multicallHandlerAddress,
            abi.encodeWithSignature(
                "outputFilled(bytes32,uint256,bytes)",
                bytes32(uint256(uint160(outputTokenAddress))),
                amount,
                remoteCallData
            )
        );
        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, multicallHandlerAddress, amount)
        );
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), output, amount);
        outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        assertEq(outputToken.balanceOf(multicallHandlerAddress), 0);
        assertEq(outputToken.balanceOf(fallbackRecipientWithCode), amount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    function test_fill_multicall_handler_calldata_eoa() public {
        address sender = makeAddr("sender");
        bytes32 orderId = keccak256(bytes("orderId"));
        uint256 amount = 10 ** 18;
        bytes32 filler = keccak256(bytes("filler"));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerAddress, amount);

        CatsMulticallHandler.Call[] memory calls = new CatsMulticallHandler.Call[](1);

        calls[0] = CatsMulticallHandler.Call({
            target: fallbackRecipient, callData: abi.encodeWithSignature("mockCall()"), value: 0
        });

        CatsMulticallHandler.Instructions memory instructions = CatsMulticallHandler.Instructions({
            setApprovalsUsingInputsFor: fallbackRecipient, calls: calls, fallbackRecipient: fallbackRecipient
        });

        bytes memory remoteCallData = abi.encode(instructions);
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(multicallHandlerAddress))),
            callbackData: remoteCallData,
            context: bytes("")
        });
        bytes memory fillerData = abi.encodePacked(filler);

        vm.prank(sender);
        vm.expectCall(
            multicallHandlerAddress,
            abi.encodeWithSignature(
                "outputFilled(bytes32,uint256,bytes)",
                bytes32(uint256(uint160(outputTokenAddress))),
                amount,
                remoteCallData
            )
        );
        vm.expectEmit();
        emit CatsMulticallHandler.CallsFailed(calls, fallbackRecipient);
        vm.expectCall(
            outputTokenAddress,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", sender, multicallHandlerAddress, amount)
        );
        vm.expectEmit();
        emit OutputFilled(orderId, filler, uint32(block.timestamp), output, amount);
        outputSettler.fill(orderId, output, type(uint48).max, fillerData);
    }

    function test_finalise_multicall_handler_simple() public {
        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettler).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
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
            inputOracle: alwaysYesOracle,
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

        CatsMulticallHandler.Call[] memory calls = new CatsMulticallHandler.Call[](0);

        CatsMulticallHandler.Instructions memory instructions = CatsMulticallHandler.Instructions({
            setApprovalsUsingInputsFor: address(0), calls: calls, fallbackRecipient: address(0)
        });

        bytes memory remoteCallData = abi.encode(instructions);

        vm.expectCall(
            multicallHandlerAddress,
            abi.encodeWithSignature("orderFinalised(uint256[2][],bytes)", inputs, remoteCallData)
        );
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
        IInputSettlerEscrow(inputSettlerEscrow)
            .finalise(order, solveParams, multicallHandlerAddress.toIdentifier(), remoteCallData);

        assertEq(token.balanceOf(multicallHandlerAddress), amount);
    }

    function test_finalise_multicall_handler_with_fallback_recipient() public {
        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettler).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
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
            inputOracle: alwaysYesOracle,
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

        CatsMulticallHandler.Call[] memory calls = new CatsMulticallHandler.Call[](1);

        calls[0] = CatsMulticallHandler.Call({
            target: fallbackRecipientWithCode, callData: abi.encodeWithSignature("mockCall()"), value: 0
        });

        CatsMulticallHandler.Instructions memory instructions = CatsMulticallHandler.Instructions({
            setApprovalsUsingInputsFor: fallbackRecipientWithCode,
            calls: calls,
            fallbackRecipient: fallbackRecipientWithCode
        });

        bytes memory remoteCallData = abi.encode(instructions);

        vm.expectCall(
            multicallHandlerAddress,
            abi.encodeWithSignature("orderFinalised(uint256[2][],bytes)", inputs, remoteCallData)
        );
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
        IInputSettlerEscrow(inputSettlerEscrow)
            .finalise(order, solveParams, multicallHandlerAddress.toIdentifier(), remoteCallData);

        assertEq(token.balanceOf(fallbackRecipientWithCode), amount);
    }

    function test_handleV3AcrossMessage_simple() public {
        address sender = makeAddr("sender");
        uint256 amount = 10 ** 18;

        CatsMulticallHandler.Call[] memory calls = new CatsMulticallHandler.Call[](0);

        CatsMulticallHandler.Instructions memory instructions = CatsMulticallHandler.Instructions({
            setApprovalsUsingInputsFor: address(0), calls: calls, fallbackRecipient: address(0)
        });

        bytes memory message = abi.encode(instructions);

        vm.prank(sender);
        multicallHandler.handleV3AcrossMessage(address(token), amount, address(0), message);
    }

    function test_handleV3AcrossMessage_with_recipient() public {
        address sender = makeAddr("sender");
        uint256 amount = 10 ** 18;

        CatsMulticallHandler.Call[] memory calls = new CatsMulticallHandler.Call[](1);

        calls[0] = CatsMulticallHandler.Call({
            target: fallbackRecipientWithCode, callData: abi.encodeWithSignature("mockCall()"), value: 0
        });

        CatsMulticallHandler.Instructions memory instructions = CatsMulticallHandler.Instructions({
            setApprovalsUsingInputsFor: fallbackRecipientWithCode,
            calls: calls,
            fallbackRecipient: fallbackRecipientWithCode
        });

        bytes memory message = abi.encode(instructions);

        vm.prank(sender);
        multicallHandler.handleV3AcrossMessage(address(token), amount, address(0), message);
    }
}
