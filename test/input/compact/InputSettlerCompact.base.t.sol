// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { TheCompact } from "the-compact/src/TheCompact.sol";
import { SimpleAllocator } from "the-compact/src/examples/allocator/SimpleAllocator.sol";
import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";
import { IdLib } from "the-compact/src/lib/IdLib.sol";
import { AlwaysOKAllocator } from "the-compact/src/test/AlwaysOKAllocator.sol";
import { ResetPeriod } from "the-compact/src/types/ResetPeriod.sol";
import { Scope } from "the-compact/src/types/Scope.sol";

import { InputSettlerBase } from "../../../src/input/InputSettlerBase.sol";
import { InputSettlerCompact } from "../../../src/input/compact/InputSettlerCompact.sol";
import { AllowOpenType } from "../../../src/input/types/AllowOpenType.sol";
import { MandateOutput, MandateOutputType } from "../../../src/input/types/MandateOutputType.sol";
import { OrderPurchase, OrderPurchaseType } from "../../../src/input/types/OrderPurchaseType.sol";
import { StandardOrder } from "../../../src/input/types/StandardOrderType.sol";
import { IInputSettlerCompact } from "../../../src/interfaces/IInputSettlerCompact.sol";

import { WormholeOracle } from "../../../src/integrations/oracles/wormhole/WormholeOracle.sol";
import { Messages } from "../../../src/integrations/oracles/wormhole/external/wormhole/Messages.sol";
import { Setters } from "../../../src/integrations/oracles/wormhole/external/wormhole/Setters.sol";
import { Structs } from "../../../src/integrations/oracles/wormhole/external/wormhole/Structs.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { OutputSettlerSimple } from "../../../src/output/simple/OutputSettlerSimple.sol";

import { AlwaysYesOracle } from "../../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

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

contract InputSettlerCompactTestBase is Test {
    address inputSettlerCompact;
    OutputSettlerSimple outputSettlerCoin;

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

    uint256 allocatorPrivateKey;
    address allocator;
    bytes12 signAllocatorLockTag;

    MockERC20 token;
    MockERC20 anotherToken;

    TheCompact public theCompact;
    address alwaysOKAllocator;
    bytes12 alwaysOkAllocatorLockTag;
    bytes32 DOMAIN_SEPARATOR;

    function setUp() public virtual {
        theCompact = new TheCompact();

        alwaysOKAllocator = address(new AlwaysOKAllocator());
        uint96 alwaysOkAllocatorId = theCompact.__registerAllocator(alwaysOKAllocator, "");
        // use scope 0 and reset period 0. This is okay as long as we don't use anything time based.
        alwaysOkAllocatorLockTag = bytes12(alwaysOkAllocatorId);
        (allocator, allocatorPrivateKey) = makeAddrAndKey("allocator");
        SimpleAllocator simpleAllocator = new SimpleAllocator(allocator, address(theCompact));
        uint96 signAllocatorId = theCompact.__registerAllocator(address(simpleAllocator), "");
        signAllocatorLockTag = bytes12(signAllocatorId);

        DOMAIN_SEPARATOR = theCompact.DOMAIN_SEPARATOR();

        inputSettlerCompact = address(new InputSettlerCompact(address(theCompact)));
        outputSettlerCoin = new OutputSettlerSimple();
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
        wormholeOracle.setChainMap(uint16(block.chainid), block.chainid);
        (testGuardian, testGuardianPrivateKey) = makeAddrAndKey("testGuardian");
        // initialize guardian set with one guardian
        address[] memory keys = new address[](1);
        keys[0] = testGuardian;
        Structs.GuardianSet memory guardianSet = Structs.GuardianSet(keys, 0);
        require(messages.quorum(guardianSet.keys.length) == 1, "Quorum should be 1");

        messages.storeGuardianSetPub(guardianSet, uint32(0));
    }

    struct Lock {
        bytes12 lockTag;
        address token;
        uint256 amount;
    }

    function getLockHash(
        uint256[2][] memory idsAndAmounts
    ) public pure returns (bytes32) {
        bytes32[] memory lockHashes = new bytes32[](idsAndAmounts.length);
        for (uint256 i; i < idsAndAmounts.length; ++i) {
            uint256[2] memory idsAndAmount = idsAndAmounts[i];
            Lock memory lock = Lock({
                lockTag: bytes12(bytes32(idsAndAmount[0])),
                token: address(uint160(idsAndAmount[0])),
                amount: idsAndAmount[1]
            });
            lockHashes[i] = keccak256(
                abi.encode(
                    keccak256(bytes("Lock(bytes12 lockTag,address token,uint256 amount)")),
                    lock.lockTag,
                    lock.token,
                    lock.amount
                )
            );
        }

        return keccak256(abi.encodePacked(lockHashes));
    }

    function getCompactBatchWitnessSignature(
        uint256 privateKey,
        address arbiter,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        uint256[2][] memory idsAndAmounts,
        bytes32 witness
    ) internal view returns (bytes memory sig) {
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        keccak256(
                            bytes(
                                "BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Lock[] commitments,Mandate mandate)Lock(bytes12 lockTag,address token,uint256 amount)Mandate(uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)"
                            )
                        ),
                        arbiter,
                        sponsor,
                        nonce,
                        expires,
                        getLockHash(idsAndAmounts),
                        witness
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function witnessHash(
        StandardOrder memory order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    bytes(
                        "Mandate(uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)"
                    )
                ),
                order.fillDeadline,
                order.inputOracle,
                hashOutputsForMemory(order.outputs)
            )
        );
    }

    function hashOutputsForMemory(
        MandateOutput[] memory outputs
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](outputs.length);
        for (uint256 i = 0; i < outputs.length; ++i) {
            MandateOutput memory output = outputs[i];
            hashes[i] = keccak256(
                abi.encode(
                    MandateOutputType.MANDATE_OUTPUT_TYPE_HASH,
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

    function getOrderPurchaseSignature(
        uint256 privateKey,
        OrderPurchase calldata orderPurchase
    ) external view returns (bytes memory sig) {
        bytes32 domainSeparator = InputSettlerBase(inputSettlerCompact).DOMAIN_SEPARATOR();
        bytes32 msgHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, OrderPurchaseType.hashOrderPurchase(orderPurchase))
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function getOrderOpenSignature(
        uint256 privateKey,
        bytes32 orderId,
        bytes32 destination,
        bytes calldata call
    ) external view returns (bytes memory sig) {
        bytes32 domainSeparator = InputSettlerBase(inputSettlerCompact).DOMAIN_SEPARATOR();
        bytes32 msgHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, AllowOpenType.hashAllowOpen(orderId, destination, call))
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function toTokenId(
        address tkn,
        Scope scope,
        ResetPeriod resetPeriod,
        address alloca
    ) internal pure returns (uint256 id) {
        // Derive the allocator ID for the provided allocator address.
        uint96 allocatorId = IdLib.toAllocatorId(alloca);

        // Derive resource lock ID (pack scope, reset period, allocator ID, & token).
        id = ((EfficiencyLib.asUint256(scope) << 255) | (EfficiencyLib.asUint256(resetPeriod) << 252)
                | (EfficiencyLib.asUint256(allocatorId) << 160) | EfficiencyLib.asUint256(tkn));
    }

    function hashOrderPurchase(
        OrderPurchase calldata orderPurchase
    ) external pure returns (bytes32) {
        return OrderPurchaseType.hashOrderPurchase(orderPurchase);
    }
}
