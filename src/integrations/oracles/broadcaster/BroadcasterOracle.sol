// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../oracles/ChainMap.sol";

import { IReceiver } from "broadcaster/interfaces/IReceiver.sol";

contract BroadcasterOracle is BaseInputOracle, ChainMap {
    using LibAddress for address;

    IReceiver private immutable _receiver;

    error InvalidBroadcasterId();

    constructor(
        IReceiver receiver_,
        address owner_
    ) ChainMap(owner_) {
        _receiver = receiver_;
    }

    function receiver() public view returns (IReceiver) {
        return _receiver;
    }

    function handle(
        IReceiver.RemoteReadArgs calldata broadcasterReadArgs,
        uint256 remoteChainId,
        address remoteOracle, // publisher
        bytes calldata messageData
    ) external {
        (bytes32 application, bytes32[] memory payloadHashes) =
            MessageEncodingLib.getHashesOfEncodedPayloads(messageData);

        bytes32 message = keccak256(abi.encodePacked(payloadHashes));

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
}

