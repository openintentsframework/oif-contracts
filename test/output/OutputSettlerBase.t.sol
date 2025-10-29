// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { OutputSettlerBase } from "../../src/output/OutputSettlerBase.sol";
import { FillerDataLib } from "../../src/output/simple/FillerDataLib.sol";

import { OutputVerificationLib } from "../../src/libs/OutputVerificationLib.sol";
import { MockCallbackExecutor } from "../mocks/MockCallbackExecutor.sol";
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

contract OutputSettlerBaseTest is Test {
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
    MockCallbackExecutor mockCallbackExecutor;

    address swapper;
    address outputSettlerAddress;
    address outputTokenAddress;
    address mockCallbackExecutorAddress;

    function setUp() public {
        outputSettler = new OutputSettlerMock();
        outputToken = new MockERC20("TEST", "TEST", 18);
        mockCallbackExecutor = new MockCallbackExecutor();

        swapper = makeAddr("swapper");
        outputSettlerAddress = address(outputSettler);
        outputTokenAddress = address(outputToken);
        mockCallbackExecutorAddress = address(mockCallbackExecutor);
    }

    function test_fill() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        bytes32 filler = keccak256(bytes("filler"));
        uint256 amount = 10 ** 18;

        vm.assume(filler != bytes32(0) && swapper != sender && sender != address(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerAddress, amount);

        bytes memory fillerData = abi.encodePacked(filler);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(0),
            settler: bytes32(uint256(uint160(outputSettlerAddress))),
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
        outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        assertEq(outputToken.balanceOf(swapper), amount);
        assertEq(outputToken.balanceOf(sender), 0);
    }

    function test_fill_and_setAttestation_self() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        bytes32 filler = keccak256(bytes("filler"));
        uint256 amount = 10 ** 18;

        vm.assume(filler != bytes32(0) && swapper != sender && sender != address(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerAddress, amount);

        bytes memory fillerData = abi.encodePacked(filler);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(outputSettlerAddress))),
            settler: bytes32(uint256(uint160(outputSettlerAddress))),
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
        outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        assertEq(outputToken.balanceOf(swapper), amount);
        assertEq(outputToken.balanceOf(sender), 0);

        outputSettler.setAttestation(orderId, filler, uint32(block.timestamp), output);
    }

    function test_setAttestation_without_fill_reverts() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        bytes32 filler = keccak256(bytes("filler"));
        uint256 amount = 10 ** 18;

        vm.assume(filler != bytes32(0) && swapper != sender && sender != address(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerAddress, amount);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(outputSettlerAddress))),
            settler: bytes32(uint256(uint160(outputSettlerAddress))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(outputTokenAddress))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            callbackData: bytes(""),
            context: bytes("")
        });

        bytes32 givenFillRecordHash = keccak256(abi.encodePacked(filler, uint32(block.timestamp)));

        vm.expectRevert(
            abi.encodeWithSelector(OutputSettlerBase.InvalidAttestation.selector, bytes32(0), givenFillRecordHash)
        );
        outputSettler.setAttestation(orderId, filler, uint32(block.timestamp), output);
    }

    function test_fill_and_setAttestation_wrongOracle_reverts() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        address sender = makeAddr("sender");
        bytes32 filler = keccak256(bytes("filler"));
        uint256 amount = 10 ** 18;

        vm.assume(filler != bytes32(0) && swapper != sender && sender != address(0));

        outputToken.mint(sender, amount);
        vm.prank(sender);
        outputToken.approve(outputSettlerAddress, amount);

        bytes memory fillerData = abi.encodePacked(filler);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(makeAddr("wrongOracle")))),
            settler: bytes32(uint256(uint160(outputSettlerAddress))),
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
        outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        assertEq(outputToken.balanceOf(swapper), amount);
        assertEq(outputToken.balanceOf(sender), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                OutputVerificationLib.WrongOutputOracle.selector, outputSettlerAddress, makeAddr("wrongOracle")
            )
        );
        outputSettler.setAttestation(orderId, filler, uint32(block.timestamp), output);
    }
}
