// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MessageEncodingLib } from "../../src/libs/MessageEncodingLib.sol";

contract MessageEncodingLibTest is Test {
    function encodeMemoryToCalldata(
        bytes32 application,
        bytes[] calldata payloads
    ) external pure returns (bytes memory encodedPayload) {
        return encodedPayload = MessageEncodingLib.encodeMessage(application, payloads);
    }

    function decodeMemoryToCalldata(
        bytes calldata encodedPayloads
    ) external pure returns (bytes32 decodedApplication, bytes32[] memory decodedPayloadHashes) {
        return MessageEncodingLib.getHashesOfEncodedPayloads(encodedPayloads);
    }

    /// forge-config: default.block_gas_limit = 100000000000
    /// forge-config: default.memory_limit = 1000000000000
    // function test_encode_lots_of_payloads_messages() external {
    //     bytes32 application = keccak256(bytes("application"));

    //     bytes[] memory payloads = new bytes[](65535);
    //     this.encodeMemoryToCalldata(application, payloads);

    //     payloads = new bytes[](65535 + 1);
    //     vm.expectRevert(abi.encodeWithSignature("TooManyPayloads(uint256)", 65535 + 1));
    //     this.encodeMemoryToCalldata(application, payloads);
    // }

    function test_revert_encode_too_large_payload() external {
        bytes32 application = keccak256(bytes("application"));

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = new bytes(65535);
        this.encodeMemoryToCalldata(application, payloads);

        payloads = new bytes[](1);
        payloads[0] = new bytes(65535 + 1);
        vm.expectRevert(abi.encodeWithSignature("TooLargePayload(uint256)", 65535 + 1));
        this.encodeMemoryToCalldata(application, payloads);
    }

    function test_encode_decode_messages(bytes32 application, bytes[] calldata payloads) external view {
        vm.assume(payloads.length < type(uint16).max);
        for (uint256 i; i < payloads.length; ++i) {
            vm.assume(payloads[i].length < type(uint16).max);
        }

        bytes memory encodedPayloads = MessageEncodingLib.encodeMessage(application, payloads);

        (bytes32 decodedApplication, bytes32[] memory decodedPayloadHashes) =
            this.decodeMemoryToCalldata(encodedPayloads);

        assertEq(decodedApplication, application);
        assertEq(decodedPayloadHashes.length, payloads.length);
        for (uint256 i; i < payloads.length; ++i) {
            assertEq(decodedPayloadHashes[i], keccak256(payloads[i]));
        }
    }
}
