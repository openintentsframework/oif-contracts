/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { GasRouter } from "@hyperlane-xyz/client/GasRouter.sol";

import { BaseOracle } from "../BaseOracle.sol";
import { IPayloadCreator } from "../../interfaces/IPayloadCreator.sol";
import { LibAddress } from "../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../libs/MessageEncodingLib.sol";

/**
 * @notice Hyperlane Oracle.
 * Implements a transparent oracle that allows both sending and receiving messages using Hyperlane protocol along with
 * exposing the hash of received messages.
 */
contract HyperlaneOracle is GasRouter, BaseOracle {
    using LibAddress for address;

    /// @dev Reserved storage slots for upgradeability.
    uint256[47] private __GAP;

    error NotAllPayloadsValid();

    /**
     * @notice Initializes the HyperlaneOracle contract with the specified Mailbox address.
     * @param _mailbox The address of the Hyperlane mailbox contract.
     */
    constructor(
        address _mailbox
    ) GasRouter(_mailbox) { }

    /**
     * @notice Initializes the Hyperlane router
     * @param _customHook used by the Router to set the hook to override with
     * @param _ism The address of the local ISM contract
     * @param _owner The address with owner privileges
     */
    function initialize(address _customHook, address _ism, address _owner) external initializer {
        _MailboxClient_initialize(_customHook, _ism, _owner);
    }

    /**
     * @notice Takes proofs that have been marked as valid by a source and dispatches them to Hyperlane mailbox for
     * broadcast.
     * @param originDomain The domain to which the message is sent.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     */
    function submit(uint32 originDomain, address source, bytes[] calldata payloads) public payable {
        if (!IPayloadCreator(source).arePayloadsValid(payloads)) revert NotAllPayloadsValid();

        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);
        _GasRouter_dispatch(originDomain, msg.value, message, address(hook));
    }

    /**
     * @notice Handles incoming messages.
     * @dev Decodes the message and processes settlement or refund operations accordingly.
     * @param messageOrigin The domain from which the message originates.
     * @param messageSender The address of the sender on the origin domain. The oracle.
     * @param message The encoded message received via Hyperlane.
     */
    function _handle(uint32 messageOrigin, bytes32 messageSender, bytes calldata message) internal virtual override {
        (bytes32 application, bytes32[] memory payloadHashes) = MessageEncodingLib.getHashesOfEncodedPayloads(message);

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i; i < numPayloads; ++i) {
            bytes32 payloadHash = payloadHashes[i];
            _attestations[messageOrigin][messageSender][application][payloadHash] = true;

            emit OutputProven(messageOrigin, messageSender, application, payloadHash);
        }
    }
}
