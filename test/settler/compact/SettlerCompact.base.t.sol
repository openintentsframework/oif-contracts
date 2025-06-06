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

import { CoinFiller } from "../../../src/fillers/coin/CoinFiller.sol";

import { ISettlerCompact } from "../../../src/interfaces/ISettlerCompact.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { WormholeOracle } from "../../../src/oracles/wormhole/WormholeOracle.sol";
import { Messages } from "../../../src/oracles/wormhole/external/wormhole/Messages.sol";
import { Setters } from "../../../src/oracles/wormhole/external/wormhole/Setters.sol";
import { Structs } from "../../../src/oracles/wormhole/external/wormhole/Structs.sol";
import { SettlerCompact } from "../../../src/settlers/compact/SettlerCompact.sol";
import { AllowOpenType } from "../../../src/settlers/types/AllowOpenType.sol";
import { MandateOutput, MandateOutputType } from "../../../src/settlers/types/MandateOutputType.sol";
import { OrderPurchase, OrderPurchaseType } from "../../../src/settlers/types/OrderPurchaseType.sol";
import { StandardOrder, StandardOrderType } from "../../../src/settlers/types/StandardOrderType.sol";

import { AlwaysYesOracle } from "../../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

interface EIP712 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface ISettlerCompactHarness is ISettlerCompact {
    function validateFills(
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32[] calldata solvers,
        uint32[] calldata timestamps
    ) external view;
}

contract SettlerCompactHarness is SettlerCompact, ISettlerCompactHarness {
    constructor(
        address compact
    ) SettlerCompact(compact) { }

    function validateFills(
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32[] calldata solvers,
        uint32[] calldata timestamps
    ) external view {
        _validateFills(order, orderId, solvers, timestamps);
    }
}

event PackagePublished(uint32 nonce, bytes payload, uint8 consistencyLevel);

contract ExportedMessages is Messages, Setters {
    function storeGuardianSetPub(Structs.GuardianSet memory set, uint32 index) public {
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

contract SettlerCompactTestBase is Test {
    address settlerCompact;
    CoinFiller coinFiller;

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

        DOMAIN_SEPARATOR = EIP712(address(theCompact)).DOMAIN_SEPARATOR();

        settlerCompact = address(new SettlerCompactHarness(address(theCompact)));
        coinFiller = new CoinFiller();
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
                                "BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,uint256[2][] idsAndAmounts,Mandate mandate)Mandate(uint32 fillDeadline,address localOracle,MandateOutput[] outputs)MandateOutput(bytes32 remoteOracle,bytes32 remoteFiller,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes remoteCall,bytes fulfillmentContext)"
                            )
                        ),
                        arbiter,
                        sponsor,
                        nonce,
                        expires,
                        keccak256(abi.encodePacked(idsAndAmounts)),
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
                        "Mandate(uint32 fillDeadline,address localOracle,MandateOutput[] outputs)MandateOutput(bytes32 remoteOracle,bytes32 remoteFiller,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes remoteCall,bytes fulfillmentContext)"
                    )
                ),
                order.fillDeadline,
                order.localOracle,
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
                            "MandateOutput(bytes32 remoteOracle,bytes32 remoteFiller,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes remoteCall,bytes fulfillmentContext)"
                        )
                    ),
                    output.remoteOracle,
                    output.remoteFiller,
                    output.chainId,
                    output.token,
                    output.amount,
                    output.recipient,
                    keccak256(output.remoteCall),
                    keccak256(output.fulfillmentContext)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function encodeMessage(bytes32 remoteIdentifier, bytes[] calldata payloads) external pure returns (bytes memory) {
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
        bytes32 domainSeparator = EIP712(settlerCompact).DOMAIN_SEPARATOR();
        bytes32 msgHash =
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, OrderPurchaseType.hashOrderPurchase(orderPurchase)));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function getOrderOpenSignature(
        uint256 privateKey,
        bytes32 orderId,
        bytes32 destination,
        bytes calldata call
    ) external view returns (bytes memory sig) {
        bytes32 domainSeparator = EIP712(settlerCompact).DOMAIN_SEPARATOR();
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
        uint96 allocatorId = IdLib.usingAllocatorId(alloca);

        // Derive resource lock ID (pack scope, reset period, allocator ID, & token).
        id = (
            (EfficiencyLib.asUint256(scope) << 255) | (EfficiencyLib.asUint256(resetPeriod) << 252)
                | (EfficiencyLib.asUint256(allocatorId) << 160) | EfficiencyLib.asUint256(tkn)
        );
    }

    function hashOrderPurchase(
        OrderPurchase calldata orderPurchase
    ) external pure returns (bytes32) {
        return OrderPurchaseType.hashOrderPurchase(orderPurchase);
    }
}
