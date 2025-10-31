// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { OutputSettlerSimple } from "../../../src/output/simple/OutputSettlerSimple.sol";

import { InputSettlerMultichainEscrow } from "../../../src/input/escrow/InputSettlerMultichainEscrow.sol";
import { AllowOpenType } from "../../../src/input/types/AllowOpenType.sol";
import { MandateOutput, MandateOutputType } from "../../../src/input/types/MandateOutputType.sol";

import {
    MultichainOrderComponent,
    MultichainOrderComponentType
} from "../../../src/input/types/MultichainOrderComponentType.sol";
import { OrderPurchase, OrderPurchaseType } from "../../../src/input/types/OrderPurchaseType.sol";

import { WormholeOracle } from "../../../src/integrations/oracles/wormhole/WormholeOracle.sol";
import { Messages } from "../../../src/integrations/oracles/wormhole/external/wormhole/Messages.sol";
import { Setters } from "../../../src/integrations/oracles/wormhole/external/wormhole/Setters.sol";
import { Structs } from "../../../src/integrations/oracles/wormhole/external/wormhole/Structs.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";

import { AlwaysYesOracle } from "../../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { Permit2Test } from "./Permit2.t.sol";

interface EIP712 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

event PackagePublished(uint32 nonce, bytes payload, uint8 consistencyLevel);

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

contract InputSettlerMultichainEscrowTestBase is Permit2Test {
    using LibAddress for uint256;

    address inputSettlerMultichainEscrow;
    OutputSettlerSimple outputSettlerSimple;

    // Oracles
    address alwaysYesOracle;
    ExportedMessages messages;
    WormholeOracle wormholeOracle;

    uint256 swapperPrivateKey;
    address swapper;
    uint256 solverPrivateKey;
    address solver;
    uint256 testGuardianPrivateKey;
    address testGuardian;

    MockERC20 token;
    MockERC20 anotherToken;

    function setUp() public virtual override {
        super.setUp();
        inputSettlerMultichainEscrow = address(new InputSettlerMultichainEscrow());
        outputSettlerSimple = new OutputSettlerSimple();
        alwaysYesOracle = address(new AlwaysYesOracle());

        token = new MockERC20("Mock ERC20", "MOCK", 18);
        anotherToken = new MockERC20("Mock2 ERC20", "MOCK2", 18);

        (swapper, swapperPrivateKey) = makeAddrAndKey("swapper");
        (solver, solverPrivateKey) = makeAddrAndKey("solver");

        // Oracles
        messages = new ExportedMessages();
        address wormholeDeployment = makeAddr("wormholeOracle");
        deployCodeTo("WormholeOracle.sol", abi.encode(address(this), address(messages)), wormholeDeployment);
        wormholeOracle = WormholeOracle(wormholeDeployment);
        wormholeOracle.setChainMap(3, 3);
        (testGuardian, testGuardianPrivateKey) = makeAddrAndKey("testGuardian");
        // initialize guardian set with one guardian
        address[] memory keys = new address[](1);
        keys[0] = testGuardian;
        Structs.GuardianSet memory guardianSet = Structs.GuardianSet(keys, 0);
        require(messages.quorum(guardianSet.keys.length) == 1, "Quorum should be 1");

        messages.storeGuardianSetPub(guardianSet, uint32(0));
    }

    function getOutputToFillFromMandateOutput(
        uint48 fillDeadline,
        MandateOutput memory output
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            fillDeadline, // fill deadline
            output.oracle, // oracle
            output.settler, // settler
            uint256(output.chainId), // chainId
            output.token, // token
            output.amount, // amount
            output.recipient, // recipient
            uint16(output.callbackData.length), // call length
            output.callbackData, // call
            uint16(output.context.length), // context length
            output.context // context
        );
    }

    function encodeMessage(
        bytes32 remoteIdentifier,
        bytes[] calldata payloads
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(remoteIdentifier, payloads);
    }

    function _buildPreMessage(
        uint16 emitterChainId,
        bytes32 emitterAddress
    ) internal pure returns (bytes memory preMessage) {
        return
            abi.encodePacked(hex"000003e8" hex"00000001", emitterChainId, emitterAddress, hex"0000000000000539" hex"0f");
    }

    function makeValidVAA(
        uint16 emitterChainId,
        bytes32 emitterAddress,
        bytes memory message
    ) internal view returns (bytes memory validVM) {
        bytes memory postvalidVM = abi.encodePacked(_buildPreMessage(emitterChainId, emitterAddress), message);
        bytes32 vmHash = keccak256(abi.encodePacked(keccak256(postvalidVM)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testGuardianPrivateKey, vmHash);

        validVM = abi.encodePacked(hex"01" hex"00000000" hex"01", uint8(0), r, s, v - 27, postvalidVM);
    }

    function getOrderOpenSignature(
        uint256 privateKey,
        bytes32 orderId,
        bytes32 destination,
        bytes calldata call
    ) external view returns (bytes memory sig) {
        bytes32 domainSeparator = EIP712(inputSettlerMultichainEscrow).DOMAIN_SEPARATOR();
        bytes32 msgHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, AllowOpenType.hashAllowOpen(orderId, destination, call))
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function witnessHash(
        MultichainOrderComponent memory order
    ) internal view returns (bytes32) {
        bytes32 orderId = InputSettlerMultichainEscrow(inputSettlerMultichainEscrow).orderIdentifier(order);
        return keccak256(
            abi.encode(
                keccak256(
                    bytes(
                        "MultichainPermit2Witness(bytes32 orderId,uint32 expires,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)"
                    )
                ),
                orderId,
                order.expires,
                order.inputOracle,
                outputsHash(order.outputs)
            )
        );
    }

    function outputsHash(
        MandateOutput[] memory outputs
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](outputs.length);
        for (uint256 i = 0; i < outputs.length; ++i) {
            MandateOutput memory output = outputs[i];
            hashes[i] = keccak256(
                abi.encode(
                    keccak256(
                        bytes(
                            "MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)"
                        )
                    ),
                    output.oracle,
                    output.settler,
                    output.chainId,
                    output.token,
                    output.amount,
                    output.recipient,
                    keccak256(output.callbackData),
                    keccak256(output.context)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function getPermit2Signature(
        uint256 privateKey,
        MultichainOrderComponent memory order
    ) internal view returns (bytes memory sig) {
        uint256[2][] memory inputs = order.inputs;
        bytes32[] memory tokenPermissionsHashes = new bytes32[](inputs.length);
        for (uint256 i; i < inputs.length; ++i) {
            uint256[2] memory input = inputs[i];
            address inputToken = input[0].fromIdentifier();
            uint256 amount = input[1];
            tokenPermissionsHashes[i] = keccak256(
                abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), inputToken, amount)
            );
        }
        bytes32 domainSeparator = EIP712(permit2).DOMAIN_SEPARATOR();
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        keccak256(
                            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,MultichainPermit2Witness witness)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)MultichainPermit2Witness(bytes32 orderId,uint32 expires,address inputOracle,MandateOutput[] outputs)TokenPermissions(address token,uint256 amount)"
                        ),
                        keccak256(abi.encodePacked(tokenPermissionsHashes)),
                        inputSettlerMultichainEscrow,
                        order.nonce,
                        order.fillDeadline,
                        witnessHash(order)
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }
}
