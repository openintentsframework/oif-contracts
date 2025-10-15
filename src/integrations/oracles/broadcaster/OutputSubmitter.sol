// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";

import { IBroadcaster } from "broadcaster/interfaces/IBroadcaster.sol";

contract OutputSubmitter {
    IBroadcaster private immutable _broadcaster;

    error NotAllPayloadsValid();
    error EmptyPayloads();

    constructor(
        IBroadcaster broadcaster_
    ) {
        _broadcaster = broadcaster_;
    }

    function broadcaster() public view returns (IBroadcaster) {
        return _broadcaster;
    }

    function submit(
        address source,
        bytes[] calldata payloads
    ) public {
        if (payloads.length == 0) revert EmptyPayloads();
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();

        bytes32 message = _getMessage(payloads);

        broadcaster().broadcastMessage(message);
    }

    function _getMessage(
        bytes[] calldata payloads
    ) internal pure returns (bytes32 message) {
        bytes32[] memory payloadHashes = new bytes32[](payloads.length);
        for (uint256 i = 0; i < payloads.length; i++) {
            payloadHashes[i] = keccak256(payloads[i]);
        }
        return keccak256(abi.encodePacked(payloadHashes));
    }
}

