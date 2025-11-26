// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { BroadcasterOracle } from "../../../src/integrations/oracles/broadcaster/BroadcasterOracle.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { OutputSettlerBase } from "../../../src/output/OutputSettlerBase.sol";
import { OutputSettlerSimple } from "../../../src/output/simple/OutputSettlerSimple.sol";
import { MockERC20 } from "../../../test/mocks/MockERC20.sol";
import { BlockHashProverPointer } from "broadcaster/BlockHashProverPointer.sol";
import { Broadcaster } from "broadcaster/Broadcaster.sol";
import { Receiver } from "broadcaster/Receiver.sol";
import { IBroadcaster } from "broadcaster/interfaces/IBroadcaster.sol";
import { IReceiver } from "broadcaster/interfaces/IReceiver.sol";
import { ChildToParentProver as ArbChildToParentProver } from "broadcaster/provers/arbitrum/ChildToParentProver.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test, console } from "forge-std/Test.sol";

interface IBuffer {
    error UnknownParentChainBlockHash(uint256 parentChainBlockNumber);

    function receiveHashes(
        uint256 firstBlockNumber,
        bytes32[] memory blockHashes
    ) external;

    function parentChainBlockHash(
        uint256 parentChainBlockNumber
    ) external view returns (bytes32);
}

contract MockBuffer is IBuffer {
    mapping(uint256 => bytes32) public parentChainBlockHashes;

    function receiveHashes(
        uint256 firstBlockNumber,
        bytes32[] memory blockHashes
    ) external {
        for (uint256 i = 0; i < blockHashes.length; i++) {
            parentChainBlockHashes[firstBlockNumber + i] = blockHashes[i];
        }
    }

    function parentChainBlockHash(
        uint256 parentChainBlockNumber
    ) external view returns (bytes32) {
        if (parentChainBlockHashes[parentChainBlockNumber] == bytes32(0)) {
            revert UnknownParentChainBlockHash(parentChainBlockNumber);
        }

        return parentChainBlockHashes[parentChainBlockNumber];
    }
}

contract BroadcasterOracleTest is Test {
    using stdJson for string;
    using LibAddress for address;

    BroadcasterOracle public broadcasterOracle;

    uint256 public ethereumForkId;
    uint256 public arbitrumForkId;

    uint256 parentChainId;
    uint256 childChainId;

    address owner = makeAddr("owner");

    IBuffer public buffer;

    function setUp() public {
        address bufferAddress = 0x0000000048C4Ed10cF14A02B9E0AbDDA5227b071;
        deployCodeTo("MockBuffer", bufferAddress);

        buffer = IBuffer(bufferAddress);
    }

    function encodeMessageCalldata(
        bytes32 identifier,
        bytes[] calldata payloads
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(identifier, payloads);
    }

    function _getPayloadForVerifyMessage()
        internal
        view
        returns (bytes memory payload, address broadcasterOracleSubmitter, address outputSettler)
    {
        broadcasterOracleSubmitter = 0x947E5E61F63d51e3B7498dfEe96A28B190eD5e8B;
        outputSettler = 0x674Cd8B4Bec9b6e9767FAa8d897Fd6De0729dd66;
        MockERC20 token = MockERC20(0x287E1E51Dad0736Dc5de7dEaC0751C21b3d88d6e);

        uint256 amount = 1 ether;
        address filler = 0x9a56fFd72F4B526c523C733F1F74197A51c495E1;
        MandateOutput memory output = MandateOutput({
            oracle: address(broadcasterOracleSubmitter).toIdentifier(),
            settler: address(outputSettler).toIdentifier(),
            chainId: 11155111,
            token: address(token).toIdentifier(),
            amount: amount,
            recipient: filler.toIdentifier(),
            callbackData: bytes(""),
            context: bytes("")
        });

        payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            filler.toIdentifier(),
            keccak256(bytes("orderId")),
            uint32(1764104508),
            output.token,
            output.amount,
            output.recipient,
            bytes(""),
            bytes("")
        );

        return (payload, broadcasterOracleSubmitter, outputSettler);
    }

    function _buildInputForVerifyMessage(
        uint256 expectedSlot
    ) internal returns (bytes memory input, uint256 blockNumber, address account) {
        string memory path = "test/oracle/broadcaster/payloads/ethereum-sepolia/broadcast_proof_block_9706376.json";
        string memory json = vm.readFile(path);
        blockNumber = json.readUint(".blockNumber");
        bytes32 blockHash = json.readBytes32(".blockHash");
        account = json.readAddress(".account");
        uint256 slot = json.readUint(".slot");
        bytes memory rlpBlockHeader = json.readBytes(".rlpBlockHeader");
        bytes memory rlpAccountProof = json.readBytes(".rlpAccountProof");
        bytes memory rlpStorageProof = json.readBytes(".rlpStorageProof");

        assertEq(bytes32(expectedSlot), bytes32(slot), "slot mismatch");

        bytes32 expectedBlockHash = keccak256(rlpBlockHeader);

        assertEq(blockHash, expectedBlockHash);

        address aliasedPusher = 0x6B6D4f3d0f0eFAeED2aeC9B59b67Ec62a4667e99;
        bytes32[] memory blockHashes = new bytes32[](1);
        blockHashes[0] = blockHash;

        vm.prank(aliasedPusher);
        buffer.receiveHashes(blockNumber, blockHashes);

        input = abi.encode(rlpBlockHeader, account, expectedSlot, rlpAccountProof, rlpStorageProof);
    }

    function test_submitOutput() public {
        Receiver receiver = new Receiver();
        Broadcaster broadcaster = new Broadcaster();
        broadcasterOracle = new BroadcasterOracle(receiver, broadcaster, owner);

        OutputSettlerSimple outputSettler = new OutputSettlerSimple();

        MockERC20 token = new MockERC20("TEST", "TEST", 18);
        address filler = makeAddr("filler");
        token.mint(filler, 1 ether);
        vm.prank(filler);
        token.approve(address(outputSettler), 1 ether);

        uint256 amount = 1 ether;
        MandateOutput memory output = MandateOutput({
            oracle: address(broadcasterOracle).toIdentifier(),
            settler: address(outputSettler).toIdentifier(),
            chainId: block.chainid,
            token: bytes32(abi.encode(address(token))),
            amount: amount,
            recipient: bytes32(abi.encode(filler)),
            callbackData: bytes(""),
            context: bytes("")
        });

        bytes memory fillerData = abi.encodePacked(filler.toIdentifier());

        bytes32 orderId = keccak256(bytes("orderId"));

        vm.expectEmit();
        emit OutputSettlerBase.OutputFilled(orderId, filler.toIdentifier(), uint32(block.timestamp), output, amount);
        vm.prank(filler);
        outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            filler.toIdentifier(),
            orderId,
            uint32(block.timestamp),
            output.token,
            output.amount,
            output.recipient,
            bytes(""),
            bytes("")
        );

        bytes32[] memory payloadHashes = new bytes32[](1);
        payloadHashes[0] = keccak256(payloads[0]);
        bytes32 expectedMessage =
            keccak256(abi.encode(address(outputSettler), keccak256(abi.encodePacked(payloadHashes))));

        vm.expectEmit();
        emit IBroadcaster.MessageBroadcast(expectedMessage, address(broadcasterOracle));
        broadcasterOracle.submit(address(outputSettler), payloads);
    }

    function test_submitOutput_reverts_with_duplicated_message() public {
        Receiver receiver = new Receiver();
        Broadcaster broadcaster = new Broadcaster();
        broadcasterOracle = new BroadcasterOracle(receiver, broadcaster, owner);

        OutputSettlerSimple outputSettler = new OutputSettlerSimple();

        MockERC20 token = new MockERC20("TEST", "TEST", 18);
        address filler = makeAddr("filler");
        token.mint(filler, 1 ether);
        vm.prank(filler);
        token.approve(address(outputSettler), 1 ether);

        uint256 amount = 1 ether;
        MandateOutput memory output = MandateOutput({
            oracle: address(broadcasterOracle).toIdentifier(),
            settler: address(outputSettler).toIdentifier(),
            chainId: block.chainid,
            token: bytes32(abi.encode(address(token))),
            amount: amount,
            recipient: bytes32(abi.encode(filler)),
            callbackData: bytes(""),
            context: bytes("")
        });

        bytes memory fillerData = abi.encodePacked(filler.toIdentifier());

        bytes32 orderId = keccak256(bytes("orderId"));

        vm.expectEmit();
        emit OutputSettlerBase.OutputFilled(orderId, filler.toIdentifier(), uint32(block.timestamp), output, amount);
        vm.prank(filler);
        outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            filler.toIdentifier(),
            orderId,
            uint32(block.timestamp),
            output.token,
            output.amount,
            output.recipient,
            bytes(""),
            bytes("")
        );

        bytes32[] memory payloadHashes = new bytes32[](1);
        payloadHashes[0] = keccak256(payloads[0]);
        bytes32 expectedMessage =
            keccak256(abi.encode(address(outputSettler), keccak256(abi.encodePacked(payloadHashes))));

        vm.expectEmit();
        emit IBroadcaster.MessageBroadcast(expectedMessage, address(broadcasterOracle));
        broadcasterOracle.submit(address(outputSettler), payloads);

        vm.expectRevert(Broadcaster.MessageAlreadyBroadcasted.selector);
        broadcasterOracle.submit(address(outputSettler), payloads);
    }

    function test_submitOutput_reverts_with_not_all_payloads_valid() public {
        Receiver receiver = new Receiver();
        Broadcaster broadcaster = new Broadcaster();
        broadcasterOracle = new BroadcasterOracle(receiver, broadcaster, owner);

        OutputSettlerSimple outputSettler = new OutputSettlerSimple();

        bytes[] memory payloads = new bytes[](1);

        payloads[0] = payloads[0] = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            bytes32(0),
            keccak256(bytes("orderId")),
            uint32(block.timestamp),
            bytes32(0),
            0,
            bytes32(0),
            bytes(""),
            bytes("")
        );

        vm.expectRevert(BroadcasterOracle.NotAllPayloadsValid.selector);
        broadcasterOracle.submit(address(outputSettler), payloads);
    }

    function test_verifyMessage_from_Ethereum_into_Arbitrum() public {
        Receiver receiver = new Receiver();

        ArbChildToParentProver childToParentProver = new ArbChildToParentProver(block.chainid);

        BlockHashProverPointer blockHashProverPointer = new BlockHashProverPointer(owner);

        broadcasterOracle = new BroadcasterOracle(receiver, new Broadcaster(), owner);

        vm.prank(owner);
        blockHashProverPointer.setImplementationAddress(address(childToParentProver));

        bytes[] memory payloads = new bytes[](1);
        address broadcasterOracleSubmitter;
        address outputSettler;
        (payloads[0], broadcasterOracleSubmitter, outputSettler) = _getPayloadForVerifyMessage();

        bytes memory input;
        uint256 blockNumber;
        address account;
        {
            bytes32[] memory payloadHashes = new bytes32[](1);
            payloadHashes[0] = keccak256(payloads[0]);
            bytes32 expectedMessage = keccak256(abi.encode(outputSettler, keccak256(abi.encodePacked(payloadHashes))));
            uint256 expectedSlot = uint256(keccak256(abi.encode(expectedMessage, address(broadcasterOracleSubmitter))));
            (input, blockNumber, account) = _buildInputForVerifyMessage(expectedSlot);
        }

        IReceiver.RemoteReadArgs memory remoteReadArgs;
        {
            address[] memory route = new address[](1);
            route[0] = address(blockHashProverPointer);

            bytes[] memory bhpInputs = new bytes[](1);
            bhpInputs[0] = abi.encode(blockNumber);

            remoteReadArgs = IReceiver.RemoteReadArgs({ route: route, bhpInputs: bhpInputs, storageProof: input });
        }

        uint256 broadcasterRemoteAccountId = uint256(
            keccak256(
                abi.encode(
                    keccak256(
                        abi.encode(
                            bytes32(0x0000000000000000000000000000000000000000000000000000000000000000),
                            address(blockHashProverPointer)
                        )
                    ),
                    account
                )
            )
        );

        vm.prank(owner);
        broadcasterOracle.setChainMap(broadcasterRemoteAccountId, 1);

        broadcasterOracle.verifyMessage(
            remoteReadArgs,
            1,
            address(broadcasterOracleSubmitter),
            this.encodeMessageCalldata(address(outputSettler).toIdentifier(), payloads)
        );
    }
}
