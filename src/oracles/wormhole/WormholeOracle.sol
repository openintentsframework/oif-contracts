// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "solady/auth/Ownable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { MandateOutput } from "../../input/types/MandateOutputType.sol";
import { IPayloadCreator } from "../../interfaces/IPayloadCreator.sol";
import { MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";

import { MessageEncodingLib } from "../../libs/MessageEncodingLib.sol";

import { BaseOracle } from "../BaseOracle.sol";
import { ChainMap } from "../ChainMap.sol";

import { WormholeVerifier } from "./external/callworm/WormholeVerifier.sol";
import { IWormhole } from "./interfaces/IWormhole.sol";

/**
 * @notice Wormhole Oracle.
 * Implements a transparent oracle that allows both sending and receiving messages along with
 * exposing the hash of received messages.
 * @dev The contract is mostly trustless but requires someone to translate Wormhole chainIds into
 * proper chainIds. These maps once set are immutable and trustless.
 */
contract WormholeOracle is ChainMap, BaseOracle, WormholeVerifier {
    error NotAllPayloadsValid();

    /// @dev Wormhole generally defines 15 to be equal to Finality
    uint8 constant WORMHOLE_CONSISTENCY = 15;

    IWormhole public immutable WORMHOLE;

    constructor(address _owner, address _wormhole) payable ChainMap(_owner) WormholeVerifier(_wormhole) {
        WORMHOLE = IWormhole(_wormhole);
    }

    // --- Sending Proofs --- //

    /**
     * @notice Takes proofs that have been marked as valid by a source and submits them to Wormhole for broadcast.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     * @param orderIds List of order ids to validate against the `IPayloadCreator`.
     * @param outputHashes List of output hashes to validate against the `IPayloadCreator`.
     * @return refund If too much value has been sent, the excess will be returned to msg.sender.
     */
    function submit(
        address source,
        bytes[] calldata payloads,
        bytes32[] calldata orderIds,
        bytes32[] calldata outputHashes
    ) public payable returns (uint256 refund) {
        require(payloads.length == orderIds.length && payloads.length == outputHashes.length, "Length mismatch");

        IPayloadCreator.FillRecord[] memory records = new IPayloadCreator.FillRecord[](payloads.length);

        for (uint256 i; i < payloads.length; ++i) {
            records[i] = IPayloadCreator.FillRecord({
                orderId: orderIds[i],
                outputHash: outputHashes[i],
                payloadHash: keccak256(payloads[i])
            });
        }

        bytes memory encodedRecords = abi.encode(records);
        if (!IPayloadCreator(source).arePayloadsValid(encodedRecords)) revert NotAllPayloadsValid();
        return _submit(source, payloads);
    }

    // --- Wormhole Logic --- //

    /**
     * @notice Submits packaged payloads to Wormhole.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads that have been checked for validity and are to be broadcasted.
     * @return refund If too much value has been sent, the excess will be returned to msg.sender.
     */
    function _submit(address source, bytes[] calldata payloads) internal returns (uint256 refund) {
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
     * @notice Takes a wormhole VAA and stores attestations of the contained payloads.
     * @param rawMessage Wormhole VAA
     */
    function receiveMessage(
        bytes calldata rawMessage
    ) external {
        (uint16 remoteMessagingProtocolChainIdentifier, bytes32 remoteSenderIdentifier, bytes calldata message) =
            _verifyPacket(rawMessage);
        (bytes32 application, bytes32[] memory payloadHashes) = MessageEncodingLib.decodeMessage(message);

        uint256 remoteChainId = _getMappedChainId(uint256(remoteMessagingProtocolChainIdentifier));

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i; i < numPayloads; ++i) {
            bytes32 payloadHash = payloadHashes[i];
            _attestations[remoteChainId][remoteSenderIdentifier][application][payloadHash] = true;

            emit OutputProven(remoteChainId, remoteSenderIdentifier, application, payloadHash);
        }
    }

    /**
     * @param _message Wormhole VAA.
     * @return sourceIdentifier Wormhole chainId of the chain the message was emitted from.
     * @return implementationIdentifier Emitter of the message.
     * @return message_ Sent message contained within the VAA as a slice.
     */
    function _verifyPacket(
        bytes calldata _message
    ) internal view returns (uint16 sourceIdentifier, bytes32 implementationIdentifier, bytes calldata message_) {
        // This uses the custom verification logic found in ./external/callworm/WormholeVerifier.sol.
        (sourceIdentifier, implementationIdentifier, message_) = parseAndVerifyVM(_message);
    }
}
