// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { WormholeOracle } from "../../../src/oracles/wormhole/WormholeOracle.sol";
import "../../../src/oracles/wormhole/external/wormhole/Messages.sol";
import "../../../src/oracles/wormhole/external/wormhole/Setters.sol";
import { OutputSettlerCoin } from "../../../src/output/coin/OutputSettlerCoin.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";

event PackagePublished(uint32 nonce, bytes payload, uint8 consistencyLevel);

contract ExportedMessages is Messages, Setters {
    function storeGuardianSetPub(Structs.GuardianSet memory set, uint32 index) public {
        return super.storeGuardianSet(set, index);
    }

    function publishMessage(
        uint32 nonce,
        bytes calldata payload,
        uint8 consistencyLevel
    ) external payable returns (uint64 sequence) {
        emit PackagePublished(nonce, payload, consistencyLevel);
        return 0;
    }
}

contract WormholeOracleTestSubmit is Test {
    WormholeOracle oracle;
    ExportedMessages messages;
    OutputSettlerCoin outputSettler;
    MockERC20 token;

    uint256 expectedValueOnCall;
    bool revertFallback = false;

    function setUp() external {
        messages = new ExportedMessages();
        oracle = new WormholeOracle(address(this), address(messages));
        outputSettler = new OutputSettlerCoin();

        token = new MockERC20("TEST", "TEST", 18);
    }

    function encodeMessageCalldata(
        bytes32 identifier,
        bytes[] calldata payloads
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(identifier, payloads);
    }

    function test_fill_then_submit_w() external {
        test_fill_then_submit(
            makeAddr("sender"),
            10 ** 18,
            makeAddr("recipient"),
            keccak256(bytes("orderId")),
            keccak256(bytes("solverIdentifier"))
        );
    }

    function test_fill_then_submit(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) public {
        vm.assume(solverIdentifier != bytes32(0));

        token.mint(sender, amount);
        vm.prank(sender);
        token.approve(address(outputSettler), amount);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(oracle)))),
            settler: bytes32(uint256(uint160(address(outputSettler)))),
            token: bytes32(abi.encode(address(token))),
            amount: amount,
            recipient: bytes32(abi.encode(recipient)),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solverIdentifier, orderId, uint32(block.timestamp), output
        );
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;

        // Fill without submitting
        vm.expectRevert(abi.encodeWithSignature("NotAllPayloadsValid()"));
        oracle.submit(address(outputSettler), payloads);

        vm.expectCall(
            address(token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(sender), recipient, amount)
        );

        vm.prank(sender);
        outputSettler.fill(type(uint32).max, orderId, output, solverIdentifier);

        bytes memory expectedPayload = this.encodeMessageCalldata(output.settler, payloads);

        vm.expectEmit();
        emit PackagePublished(0, expectedPayload, 15);
        oracle.submit(address(outputSettler), payloads);
        vm.snapshotGasLastCall("oracle", "wormholeOracleSubmit");
    }

    function test_submit_excess_value(uint64 val, bytes[] calldata payloads) external {
        expectedValueOnCall = val;
        oracle.submit{ value: val }(address(this), payloads);
    }

    function test_revert_submit_excess_value(uint64 val, bytes[] calldata payloads) external {
        revertFallback = true;
        expectedValueOnCall = val;

        if (val > 0) vm.expectRevert();
        oracle.submit{ value: val }(address(this), payloads);
    }

    function arePayloadsValid(
        bytes[] calldata
    ) external pure returns (bool) {
        return true;
    }

    receive() external payable {
        assertEq(msg.value, expectedValueOnCall);
        require(!revertFallback);
    }
}
