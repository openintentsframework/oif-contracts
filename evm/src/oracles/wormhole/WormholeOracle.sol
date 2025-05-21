// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Ownable } from "solady/auth/Ownable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { WormholeVerifier } from "./external/callworm/WormholeVerifier.sol";
import { IWormhole } from "./interfaces/IWormhole.sol";

import { BaseOracle } from "../BaseOracle.sol";
import { IPayloadCreator } from "src/interfaces/IPayloadCreator.sol";
import { MessageEncodingLib } from "src/libs/MessageEncodingLib.sol";

/**
 * @notice Wormhole Oracle.
 * Implements a transparent oracle that allows both sending and receiving messages along with
 * exposing the hash of received messages.
 * @dev The contract is mostly trustless but requires someone to translate Wormhole chainIds into
 * proper chainIds. These maps once set are immutable and trustless.
 */
contract WormholeOracle is BaseOracle, WormholeVerifier, Ownable {
    error AlreadySet();
    error NotAllPayloadsValid();
    error ZeroValue();

    event MapMessagingProtocolIdentifierToChainId(uint16 messagingProtocolIdentifier, uint256 chainId);

    /**
     * @notice Takes a chain identifier from Wormhole and translates it to "ordinary" chain ids.
     * @dev This allows us to translate incoming messages from messaging protocols to easy to
     * understand chain ids that match the most common and available identifier for chains. (their actual
     * identifier) rather than an arbitrary index which is what most messaging protocols use.
     */
    mapping(uint16 messagingProtocolChainIdentifier => uint256 blockChainId) _chainIdentifierToBlockChainId;
    /**
     * @dev The map is bi-directional.
     */
    mapping(uint256 blockChainId => uint16 messagingProtocolChainIdentifier) _blockChainIdToChainIdentifier;

    /**
     * @dev Wormhole generally defines 15 to be equal to Finality
     */
    uint8 constant WORMHOLE_CONSISTENCY = 15;

    IWormhole public immutable WORMHOLE;

    constructor(address _owner, address _wormhole) payable WormholeVerifier(_wormhole) {
        _initializeOwner(_owner);
        WORMHOLE = IWormhole(_wormhole);
    }

    // --- Chain ID Functions --- //

    /**
     * @notice Sets an immutable map of the identifier messaging protocols use to chain ids.
     * @dev Can only be called once for every chain.
     * @param messagingProtocolChainIdentifier Messaging provider identifier for a chain.
     * @param chainId Most common identifier for a chain. For EVM, it can often be accessed through block.chainid.
     */
    function setChainMap(uint16 messagingProtocolChainIdentifier, uint256 chainId) external onlyOwner {
        // Check that the inputs haven't been mistakenly called with 0 values.
        if (messagingProtocolChainIdentifier == 0) revert ZeroValue();
        if (chainId == 0) revert ZeroValue();

        // This call only allows setting either value once, then they are done for.
        // We need to check if they are currently unset.
        if (_chainIdentifierToBlockChainId[messagingProtocolChainIdentifier] != 0) revert AlreadySet();
        if (_blockChainIdToChainIdentifier[chainId] != 0) revert AlreadySet();

        _chainIdentifierToBlockChainId[messagingProtocolChainIdentifier] = chainId;
        _blockChainIdToChainIdentifier[chainId] = messagingProtocolChainIdentifier;

        emit MapMessagingProtocolIdentifierToChainId(messagingProtocolChainIdentifier, chainId);
    }

    /**
     * @param messagingProtocolChainIdentifier Messaging protocol chain identifier
     * @return chainId Common chain identifier
     */
    function getChainIdentifierToBlockChainId(
        uint16 messagingProtocolChainIdentifier
    ) external view returns (uint256 chainId) {
        return _chainIdentifierToBlockChainId[messagingProtocolChainIdentifier];
    }

    /**
     * @param chainId Common chain identifier
     * @return messagingProtocolChainIdentifier Messaging protocol chain identifier.
     */
    function getBlockChainIdToChainIdentifier(
        uint256 chainId
    ) external view returns (uint16 messagingProtocolChainIdentifier) {
        return _blockChainIdToChainIdentifier[chainId];
    }

    // --- Sending Proofs & Generalised Incentives --- //

    /**
     * @notice Takes proofs that have been marked as valid by a source and submits them to Wormhole for broadcast.
     * @param proofSource Application that has payloads that are marked as valid.
     * @param payloads List of payloads that are checked for validity against the application and broadcasted.
     */
    function submit(address proofSource, bytes[] calldata payloads) public payable returns (uint256 refund) {
        // Check if the payloads are valid.
        uint256 numPayloads = payloads.length;
        bytes32[] memory payloadHashes = new bytes32[](numPayloads);
        for (uint256 i; i < numPayloads; ++i) {
            payloadHashes[i] = keccak256(payloads[i]);
        }
        if (!IPayloadCreator(proofSource).arePayloadsValid(payloadHashes)) revert NotAllPayloadsValid();

        // Payloads are good. We can submit them on behalf of proofSource.
        return _submit(proofSource, payloads);
    }

    // --- Wormhole Logic --- //

    /**
     * @notice Submits a proof the associated messaging protocol.
     * @dev Refunds excess value to msg.sender.
     */
    function _submit(address source, bytes[] calldata payloads) internal returns (uint256 refund) {
        // This call fails if fillDeadlines.length < outputs.length
        bytes memory message = MessageEncodingLib.encodeMessage(bytes32(uint256(uint160(source))), payloads);

        uint256 packageCost = WORMHOLE.messageFee();
        WORMHOLE.publishMessage{ value: packageCost }(0, message, WORMHOLE_CONSISTENCY);

        // Refund excess value if any.
        if (msg.value > packageCost) {
            refund = msg.value - packageCost;
            SafeTransferLib.safeTransferETH(msg.sender, refund);
        }
    }

    /**
     * @notice Takes a wormhole VAA, which is expected to be from another WormholeOracle implementation
     * and stores attestations of the hash of the payloads contained within the VAA message.
     */
    function receiveMessage(
        bytes calldata rawMessage
    ) external {
        // Verify Packet and return message identifiers that Wormhole attached.
        (uint16 remoteMessagingProtocolChainIdentifier, bytes32 remoteSenderIdentifier, bytes calldata message) =
            _verifyPacket(rawMessage);
        // Decode message.
        (bytes32 application, bytes32[] memory payloadHashes) = MessageEncodingLib.decodeMessage(message);

        // Map remoteMessagingProtocolChainIdentifier to canonical chain id. This ensures we use canonical ids.
        uint256 remoteChainId = _chainIdentifierToBlockChainId[remoteMessagingProtocolChainIdentifier];
        if (remoteChainId == 0) revert ZeroValue();

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i; i < numPayloads; ++i) {
            // Store payload attestations;
            bytes32 payloadHash = payloadHashes[i];
            _attestations[remoteChainId][remoteSenderIdentifier][application][payloadHash] = true;

            emit OutputProven(remoteChainId, remoteSenderIdentifier, application, payloadHash);
        }
    }

    /**
     * @dev _message is the entire Wormhole VAA. It contains both the proof & the message as a slice.
     */
    function _verifyPacket(
        bytes calldata _message
    ) internal view returns (uint16 sourceIdentifier, bytes32 implementationIdentifier, bytes calldata message_) {
        // Decode & verify the VAA.
        // This uses the custom verification logic found in ./external/callworm/WormholeVerifier.sol.
        (sourceIdentifier, implementationIdentifier, message_) = parseAndVerifyVM(_message);
    }
}
