// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { OutputSettlerBase } from "../../src/output/OutputSettlerBase.sol";
import { FillerDataLib } from "../../src/output/simple/FillerDataLib.sol";

import { CatsMulticallHandler } from "../../src/integrations/CatsMulticallHandler.sol";
import { OutputVerificationLib } from "../../src/libs/OutputVerificationLib.sol";
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
            setApprovalsUsingInputsFor: address(0),
            calls: calls,
            fallbackRecipient: address(0)
        });

        bytes memory remoteCallData = abi.encode(instructions);
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(multicallHandlerAddress))),
            call: remoteCallData,
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
            target: fallbackRecipientWithCode,
            callData: abi.encodeWithSignature("mockCall()"),
            value: 0
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
            call: remoteCallData,
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
}
