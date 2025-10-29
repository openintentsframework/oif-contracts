// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { WormholeVerifier } from "../../../src/integrations/oracles/wormhole/external/callworm/WormholeVerifier.sol";
import "../../../src/integrations/oracles/wormhole/external/wormhole/Messages.sol";
import "../../../src/integrations/oracles/wormhole/external/wormhole/Setters.sol";
import "../../../src/integrations/oracles/wormhole/external/wormhole/Structs.sol";

contract ExportedMessages is Messages, Setters {
    function storeGuardianSetPub(
        Structs.GuardianSet memory set,
        uint32 index
    ) public {
        return super.storeGuardianSet(set, index);
    }
}

contract WormholeVerifierTest is Test {
    bytes prevalidVM = hex"01" hex"00000000" hex"01";

    address testGuardianPub;
    uint256 testGuardian;

    ExportedMessages messages;

    WormholeVerifier verifier;

    Structs.GuardianSet guardianSet;

    function setUp() public {
        (testGuardianPub, testGuardian) = makeAddrAndKey("signer");

        messages = new ExportedMessages();

        verifier = new WormholeVerifier(address(messages));

        // initialize guardian set with one guardian
        address[] memory keys = new address[](1);
        keys[0] = vm.addr(testGuardian);
        guardianSet = Structs.GuardianSet(keys, 0);
        require(messages.quorum(guardianSet.keys.length) == 1, "Quorum should be 1");

        messages.storeGuardianSetPub(guardianSet, uint32(0));
    }

    function makeValidVM(
        bytes memory message
    ) internal view returns (bytes memory validVM) {
        bytes memory postvalidVM =
            abi.encodePacked(buildPreMessage(0x000d, bytes32(uint256(0xdeadbeefbeefdead))), message);
        bytes32 vmHash = keccak256(abi.encodePacked(keccak256(postvalidVM)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testGuardian, vmHash);

        validVM = abi.encodePacked(prevalidVM, uint8(0), r, s, v - 27, postvalidVM);
    }

    function buildPreMessage(
        uint16 emitterChainId,
        bytes32 emitterAddress
    ) internal pure returns (bytes memory preMessage) {
        return
            abi.encodePacked(hex"000003e8" hex"00000001", emitterChainId, emitterAddress, hex"0000000000000539" hex"0f");
    }

    // This test checks the possibility of getting a unsigned message verified through verifyVM
    function test_compare_wormhole_implementation_and_calldata_version(
        bytes calldata message
    ) public view {
        bytes memory validVM = makeValidVM(message);
        // Confirm that the test VM is valid
        (Structs.VM memory parsedValidVm, bool valid, string memory reason) = messages.parseAndVerifyVM(validVM);

        (uint16 remoteMessagingProtocolChainIdentifier, bytes32 remoteSenderIdentifier, bytes memory collectedMessage) =
            verifier.parseAndVerifyVM(validVM);

        require(valid, reason);
        assertEq(valid, true);
        assertEq(reason, "");

        assertEq(parsedValidVm.payload, collectedMessage, "payload");
        assertEq(message, collectedMessage, "payload");
        assertEq(parsedValidVm.emitterChainId, remoteMessagingProtocolChainIdentifier, "emitterChainId");
        assertEq(parsedValidVm.emitterAddress, remoteSenderIdentifier, "emitterAddress");
    }

    function test_error_invalid_vm(
        bytes calldata message
    ) public {
        bytes memory validVM = makeValidVM(message);
        bytes memory invalidVM = abi.encodePacked(validVM, uint8(1));

        // Confirm that the test VM is valid
        (, bool valid, string memory reason) = messages.parseAndVerifyVM(invalidVM);

        vm.expectRevert(abi.encodeWithSignature("VMSignatureInvalid()"));
        verifier.parseAndVerifyVM(invalidVM);

        assertEq(valid, false);
        assertEq(reason, "VM signature invalid");
    }
}
