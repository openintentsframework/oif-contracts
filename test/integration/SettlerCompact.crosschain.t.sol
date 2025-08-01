// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test, console } from "forge-std/Test.sol";

import { TheCompact } from "the-compact/src/TheCompact.sol";
import { SimpleAllocator } from "the-compact/src/examples/allocator/SimpleAllocator.sol";
import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";
import { IdLib } from "the-compact/src/lib/IdLib.sol";
import { AlwaysOKAllocator } from "the-compact/src/test/AlwaysOKAllocator.sol";
import { ResetPeriod } from "the-compact/src/types/ResetPeriod.sol";
import { Scope } from "the-compact/src/types/Scope.sol";

import { OutputSettlerCoin } from "../../src/output/coin/OutputSettlerCoin.sol";

import { InputSettlerCompact } from "../../src/input/compact/InputSettlerCompact.sol";
import { AllowOpenType } from "../../src/input/types/AllowOpenType.sol";
import { MandateOutput, MandateOutputType } from "../../src/input/types/MandateOutputType.sol";
import { StandardOrder, StandardOrderType } from "../../src/input/types/StandardOrderType.sol";
import { IInputSettlerCompact } from "../../src/interfaces/IInputSettlerCompact.sol";
import { MandateOutputEncodingLib } from "../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../src/libs/MessageEncodingLib.sol";
import { WormholeOracle } from "../../src/oracles/wormhole/WormholeOracle.sol";
import { Messages } from "../../src/oracles/wormhole/external/wormhole/Messages.sol";
import { Setters } from "../../src/oracles/wormhole/external/wormhole/Setters.sol";
import { Structs } from "../../src/oracles/wormhole/external/wormhole/Structs.sol";

import { LibAddress } from "../../src/libs/LibAddress.sol";
import { AlwaysYesOracle } from "../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

interface EIP712 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface ImmutableCreate2Factory {
    function safeCreate2(
        bytes32 salt,
        bytes calldata initializationCode
    ) external payable returns (address deploymentAddress);
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

contract InputSettlerCompactTestCrossChain is Test {
    using LibAddress for address;

    address inputSettlerCompact;
    OutputSettlerCoin outputSettlerCoin;

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

        inputSettlerCompact = address(new InputSettlerCompact(address(theCompact)));
        outputSettlerCoin = new OutputSettlerCoin();
        alwaysYesOracle = address(new AlwaysYesOracle());

        token = new MockERC20("Mock ERC20", "MOCK", 18);
        anotherToken = new MockERC20("Mock2 ERC20", "MOCK2", 18);

        (swapper, swapperPrivateKey) = makeAddrAndKey("swapper");
        (solver, solverPrivateKey) = makeAddrAndKey("solver");

        token.mint(swapper, 1e18);

        token.mint(solver, 1e18);
        anotherToken.mint(solver, 1e18);

        vm.prank(swapper);
        token.approve(address(theCompact), type(uint256).max);
        vm.prank(solver);
        anotherToken.approve(address(outputSettlerCoin), type(uint256).max);
        vm.prank(solver);
        token.approve(address(outputSettlerCoin), type(uint256).max);

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
                                "BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Lock[] commitments,Mandate mandate)Lock(bytes12 lockTag,address token,uint256 amount)Mandate(uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
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
                        "Mandate(uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
                    )
                ),
                order.fillDeadline,
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
                            "MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
                        )
                    ),
                    output.oracle,
                    output.settler,
                    output.chainId,
                    output.token,
                    output.amount,
                    output.recipient,
                    keccak256(output.call),
                    keccak256(output.context)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function encodeMessage(bytes32 remoteIdentifier, bytes[] calldata payloads) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(remoteIdentifier, payloads);
    }

    function getOrderOpenSignature(
        uint256 privateKey,
        bytes32 orderId,
        bytes32 destination,
        bytes calldata call
    ) external view returns (bytes memory sig) {
        bytes32 domainSeparator = EIP712(inputSettlerCompact).DOMAIN_SEPARATOR();
        bytes32 msgHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, AllowOpenType.hashAllowOpen(orderId, destination, call))
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function test_deposit_compact() external {
        vm.prank(swapper);
        theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, 1e18 / 10, swapper);
    }

    function test_deposit_and_claim() external {
        vm.prank(swapper);
        uint256 amount = 1e18 / 10;
        uint256 tokenId = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, amount, swapper);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [tokenId, amount];
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: bytes32(0),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: bytes32(tokenId),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

        // Make Compact
        uint256[2][] memory idsAndAmounts = new uint256[2][](1);
        idsAndAmounts[0] = [tokenId, amount];

        bytes memory sponsorSig = getCompactBatchWitnessSignature(
            swapperPrivateKey, inputSettlerCompact, swapper, 0, type(uint32).max, idsAndAmounts, witnessHash(order)
        );
        bytes memory allocatorSig = hex"";

        bytes memory signature = abi.encode(sponsorSig, allocatorSig);

        uint32[] memory timestamps = new uint32[](1);

        vm.prank(solver);
        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = solver.toIdentifier();
        IInputSettlerCompact(inputSettlerCompact).finalise(order, signature, timestamps, solvers, solvers[0], hex"");
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

    /// forge-config: default.isolate = true
    function test_entire_flow() external {
        vm.prank(swapper);
        uint256 amount = 1e18 / 10;
        uint256 tokenId = theCompact.depositERC20(address(token), signAllocatorLockTag, amount, swapper);

        address inputOracle = address(wormholeOracle);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [tokenId, amount];
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: inputOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            inputOracle: inputOracle,
            inputs: inputs,
            outputs: outputs
        });

        // Make Compact
        uint256[2][] memory idsAndAmounts = new uint256[2][](1);
        idsAndAmounts[0] = [tokenId, amount];

        bytes memory sponsorSig = getCompactBatchWitnessSignature(
            swapperPrivateKey, inputSettlerCompact, swapper, 0, type(uint32).max, idsAndAmounts, witnessHash(order)
        );
        bytes memory allocatorSig = getCompactBatchWitnessSignature(
            allocatorPrivateKey, inputSettlerCompact, swapper, 0, type(uint32).max, idsAndAmounts, witnessHash(order)
        );

        bytes memory signature = abi.encode(sponsorSig, allocatorSig);

        // Initiation is over. We need to fill the order.

        bytes32 solverIdentifier = solver.toIdentifier();

        bytes32 orderId = IInputSettlerCompact(inputSettlerCompact).orderIdentifier(order);

        vm.prank(solver);
        outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], solverIdentifier);
        vm.snapshotGasLastCall("inputSettler", "IntegrationCoinFill");

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solverIdentifier, orderId, uint32(block.timestamp), outputs[0]
        );

        bytes memory expectedMessageEmitted = this.encodeMessage(outputs[0].settler, payloads);

        vm.expectEmit();
        emit PackagePublished(0, expectedMessageEmitted, 15);
        wormholeOracle.submit(address(outputSettlerCoin), payloads);
        vm.snapshotGasLastCall("inputSettler", "IntegrationWormholeSubmit");

        bytes memory vaa =
            makeValidVAA(uint16(block.chainid), address(wormholeOracle).toIdentifier(), expectedMessageEmitted);

        wormholeOracle.receiveMessage(vaa);
        vm.snapshotGasLastCall("inputSettler", "IntegrationWormholeReceiveMessage");

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        vm.prank(solver);
        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = solver.toIdentifier();
        IInputSettlerCompact(inputSettlerCompact).finalise(order, signature, timestamps, solvers, solvers[0], hex"");
        vm.snapshotGasLastCall("inputSettler", "IntegrationCompactFinaliseSelf");
    }

    function test_entire_flow_different_solvers(
        bytes32 solverIdentifier2
    ) external {
        bytes32 solverIdentifier = solver.toIdentifier();
        vm.assume(solverIdentifier != solverIdentifier2);
        vm.assume(bytes32(0) != solverIdentifier2);

        vm.prank(swapper);
        uint256 amount = 1e18 / 10;
        uint256 tokenId = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, amount, swapper);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [tokenId, amount];
        MandateOutput[] memory outputs = new MandateOutput[](2);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: address(wormholeOracle).toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });
        outputs[1] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: address(wormholeOracle).toIdentifier(),
            chainId: block.chainid,
            token: address(token).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            inputOracle: address(wormholeOracle),
            inputs: inputs,
            outputs: outputs
        });

        bytes memory signature;
        // Make Compact
        {
            uint256[2][] memory idsAndAmounts = new uint256[2][](1);
            idsAndAmounts[0] = [tokenId, amount];

            bytes memory sponsorSig = getCompactBatchWitnessSignature(
                swapperPrivateKey, inputSettlerCompact, swapper, 0, type(uint32).max, idsAndAmounts, witnessHash(order)
            );

            signature = abi.encode(sponsorSig, hex"");
        }
        // Initiation is over. We need to fill the order.

        {
            bytes32 orderId = IInputSettlerCompact(inputSettlerCompact).orderIdentifier(order);

            vm.prank(solver);
            outputSettlerCoin.fill(type(uint32).max, orderId, outputs[0], solverIdentifier);

            vm.prank(solver);
            outputSettlerCoin.fill(type(uint32).max, orderId, outputs[1], solverIdentifier2);

            bytes[] memory payloads = new bytes[](2);
            payloads[0] = MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solverIdentifier, orderId, uint32(block.timestamp), outputs[0]
            );
            payloads[1] = MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solverIdentifier2, orderId, uint32(block.timestamp), outputs[1]
            );

            bytes memory expectedMessageEmitted = this.encodeMessage(outputs[0].settler, payloads);

            vm.expectEmit();
            emit PackagePublished(0, expectedMessageEmitted, 15);
            wormholeOracle.submit(address(outputSettlerCoin), payloads);

            bytes memory vaa =
                makeValidVAA(uint16(block.chainid), address(wormholeOracle).toIdentifier(), expectedMessageEmitted);

            wormholeOracle.receiveMessage(vaa);
        }
        uint32[] memory timestamps = new uint32[](2);
        timestamps[0] = uint32(block.timestamp);
        timestamps[1] = uint32(block.timestamp);

        vm.expectRevert(abi.encodeWithSignature("NotProven()"));
        vm.prank(solver);
        {
            bytes32[] memory solvers = new bytes32[](2);
            solvers[0] = solverIdentifier;
            solvers[1] = solverIdentifier;
            IInputSettlerCompact(inputSettlerCompact).finalise(
                order, signature, timestamps, solvers, solverIdentifier, hex""
            );
        }

        bytes32[] memory solverIdentifierList = new bytes32[](2);
        solverIdentifierList[0] = solverIdentifier;
        solverIdentifierList[1] = solverIdentifier2;
        {
            uint256 snapshotId = vm.snapshot();

            vm.prank(solver);
            IInputSettlerCompact(inputSettlerCompact).finalise(
                order, signature, timestamps, solverIdentifierList, solverIdentifier, hex""
            );

            vm.revertTo(snapshotId);
        }
        bytes memory solverSignature = this.getOrderOpenSignature(
            solverPrivateKey, IInputSettlerCompact(inputSettlerCompact).orderIdentifier(order), solverIdentifier, hex""
        );

        vm.prank(solver);
        IInputSettlerCompact(inputSettlerCompact).finaliseWithSignature(
            order, signature, timestamps, solverIdentifierList, solverIdentifier, hex"", solverSignature
        );
    }
}
