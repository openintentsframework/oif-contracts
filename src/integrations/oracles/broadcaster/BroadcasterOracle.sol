// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../oracles/ChainMap.sol";

import { IBroadcaster } from "broadcaster/interfaces/IBroadcaster.sol";
import { IReceiver } from "broadcaster/interfaces/IReceiver.sol";

/**
 * @notice Broadcaster Oracle
 * Implements a transparent oracle that allows both for broadcasting messages and verifying them at the destination,
 * relying on storage proofs. This oracle only works for communication between chains that are in the Ethereum
 * ecosystem, i.e., Ethereum and its rollups.
 * @dev In this oracle, `ChainMap` maps EVM `chainId` to `broadcasterId` (not to chain identifiers).
 * The `broadcasterId` depends on the configured `BlockHashProverPointer`; for each remote chain, only one pointer
 * (and thus one broadcasterId) is supported.
 */
contract BroadcasterOracle is BaseInputOracle, ChainMap {
    using LibAddress for address;

    /// @dev The receiver contract that will be used to verify the messages. ERC 7888 compliant.
    IReceiver private immutable _receiver;
    /// @dev The broadcaster contract that will be used to broadcast the messages. ERC 7888 compliant.
    IBroadcaster private immutable _broadcaster;

    /// @dev Error thrown when the payloads are not valid.
    error NotAllPayloadsValid();
    /// @dev Error thrown when the broadcaster id is invalid.
    error InvalidBroadcasterId();
    /// @dev Error thrown when the broadcaster is invalid.
    error InvalidBroadcaster();
    /// @dev Error thrown when the receiver is invalid.
    error InvalidReceiver();

    constructor(
        IReceiver receiver_,
        IBroadcaster broadcaster_,
        address owner_
    ) ChainMap(owner_) {
        if (address(receiver_) == address(0)) revert InvalidReceiver();
        if (address(broadcaster_) == address(0)) revert InvalidBroadcaster();
        _receiver = receiver_;
        _broadcaster = broadcaster_;
    }

    /**
     * @notice Returns the receiver contract.
     * @return The receiver contract.
     */
    function receiver() public view returns (IReceiver) {
        return _receiver;
    }

    /**
     * @notice Returns the broadcaster contract.
     * @return The broadcaster contract.
     */
    function broadcaster() public view returns (IBroadcaster) {
        return _broadcaster;
    }

    /**
     * @notice Verifies a message broadcasted in a remote chain.
     * @param broadcasterReadArgs The arguments required to read the broadcaster's account on the remote chain.
     * @param remoteChainId The chain id of the remote chain.
     * @param remoteOracle The address of the remote oracle.
     * @param messageData The data of the message to verify.
     * @dev In this oracle, `ChainMap` maps EVM `chainId` to `broadcasterId` (not to chain identifiers).
     * The `broadcasterId` depends on the configured `BlockHashProverPointer`; for each remote chain, only one pointer
     * (and thus one broadcasterId) is supported.
     */
    function verifyMessage(
        IReceiver.RemoteReadArgs calldata broadcasterReadArgs,
        uint256 remoteChainId,
        address remoteOracle, // publisher
        bytes calldata messageData
    ) external {
        (bytes32 application, bytes32[] memory payloadHashes) =
            MessageEncodingLib.getHashesOfEncodedPayloads(messageData);

        bytes32 message = _hashPayloadHashes(payloadHashes);

        bytes32 broadcasterId = bytes32(reverseChainIdMap[remoteChainId]);

        (bytes32 actualBroadcasterId,) = receiver().verifyBroadcastMessage(broadcasterReadArgs, message, remoteOracle);

        if (actualBroadcasterId != broadcasterId) revert InvalidBroadcasterId();

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i = 0; i < numPayloads; i++) {
            bytes32 payloadHash = payloadHashes[i];
            _attestations[remoteChainId][remoteOracle.toIdentifier()][application][payloadHash] = true;

            emit OutputProven(remoteChainId, remoteOracle.toIdentifier(), application, payloadHash);
        }
    }

    /**
     * @notice Submits a proof of filled payloads as a message to the broadcaster.
     * @param source The address of the application that has attested the payloads.
     * @param payloads The payloads to submit.
     */
    function submit(
        address source,
        bytes[] calldata payloads
    ) public {
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();

        bytes32 message = _getMessage(payloads);

        broadcaster().broadcastMessage(message);
    }

    /**
     * @notice Hashes an array of payload hashes.
     * @param payloadHashes The payload hashes to hash.
     * @return digest The hashed payload hashes.
     */
    function _hashPayloadHashes(
        bytes32[] memory payloadHashes
    ) internal pure returns (bytes32 digest) {
        assembly {
            // len = payloadHashes.length
            let len := mload(payloadHashes)
            // pointer to first element (skip the length word)
            let start := add(payloadHashes, 0x20)
            // total bytes = len * 32
            let size := mul(len, 0x20)
            // keccak256 over the packed elements
            digest := keccak256(start, size)
        }
        return digest;
    }

    /**
     * @notice Generates a message from the payloads.
     * @param payloads The payloads to generate the message from.
     * @return message The message generated from the payloads.
     */
    function _getMessage(
        bytes[] calldata payloads
    ) internal pure returns (bytes32 message) {
        bytes32[] memory payloadHashes = new bytes32[](payloads.length);
        for (uint256 i = 0; i < payloads.length; i++) {
            payloadHashes[i] = keccak256(payloads[i]);
        }
        return _hashPayloadHashes(payloadHashes);
    }
}

