/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";

import { MailboxClient } from "./external/hyperlane/MailboxClient.sol";

import { IMessageRecipient } from "./external/hyperlane/interfaces/IMessageRecipient.sol";
import { IPostDispatchHook } from "./external/hyperlane/interfaces/hooks/IPostDispatchHook.sol";
import { StandardHookMetadata } from "./external/hyperlane/libs/StandardHookMetadata.sol";

/**
 * @notice Hyperlane Oracle.
 * Implements a transparent oracle that allows both sending and receiving messages using Hyperlane protocol along with
 * exposing the hash of received messages.
 */
contract HyperlaneOracle is BaseInputOracle, MailboxClient, IMessageRecipient {
    using LibAddress for address;

    error NotAllPayloadsValid();

    /**
     * @notice Initializes the HyperlaneOracle contract with the specified Mailbox address, sets the address of the
     * application's custom interchain security module and the address of the application's custom hook.
     * @param mailbox The address of the Hyperlane mailbox contract.
     * @param customHook The address of the custom hook.
     * @param ism The address of the local ISM contract.
     */
    constructor(
        address mailbox,
        address customHook,
        address ism
    ) MailboxClient(mailbox, customHook, ism) { }

    /**
     * @notice Handles incoming Hyperlane messages.
     * @param messageOrigin The domain from which the message originates.
     * @param messageSender The address of the sender on the origin domain. The oracle.
     * @param message The encoded message received via Hyperlane.
     */
    function handle(
        uint32 messageOrigin,
        bytes32 messageSender,
        bytes calldata message
    ) external payable virtual override onlyMailbox {
        (bytes32 application, bytes32[] memory payloadHashes) = MessageEncodingLib.getHashesOfEncodedPayloads(message);

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i; i < numPayloads; ++i) {
            bytes32 payloadHash = payloadHashes[i];
            _attestations[messageOrigin][messageSender][application][payloadHash] = true;

            emit OutputProven(messageOrigin, messageSender, application, payloadHash);
        }
    }

    /**
     * @notice Takes proofs that have been marked as valid by a source and dispatches them to Hyperlane's Mailbox for
     * broadcast.
     * @param destinationDomain The domain to which the message is sent.
     * @param recipientOracle The address of the oracle on the destination domain.
     * @param gasLimit Gas limit for the message.
     * @param customMetadata Additional metadata to include in the standard hook metadata.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     */
    function submit(
        uint32 destinationDomain,
        address recipientOracle,
        uint256 gasLimit,
        bytes calldata customMetadata,
        address source,
        bytes[] calldata payloads
    ) public payable {
        _submit(
            destinationDomain,
            recipientOracle,
            StandardHookMetadata.formatMetadata(0, gasLimit, msg.sender, customMetadata),
            hook(),
            source,
            payloads
        );
    }

    /**
     * @notice Takes proofs that have been marked as valid by a source and dispatches them to Hyperlane's Mailbox for
     * broadcast.
     * @param destinationDomain The domain to which the message is sent.
     * @param recipientOracle The address of the oracle on the destination domain.
     * @param gasLimit Gas limit for the message.
     * @param customMetadata Additional metadata to include in the standard hook metadata.
     * @param customHook Custom hook to be used instead of the one already configured in this client.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     */
    function submit(
        uint32 destinationDomain,
        address recipientOracle,
        uint256 gasLimit,
        bytes calldata customMetadata,
        IPostDispatchHook customHook,
        address source,
        bytes[] calldata payloads
    ) public payable {
        _submit(
            destinationDomain,
            recipientOracle,
            StandardHookMetadata.formatMetadata(0, gasLimit, msg.sender, customMetadata),
            customHook,
            source,
            payloads
        );
    }

    /**
     * @notice Returns the gas payment required to dispatch a message to the given domain's oracle.
     * @param destinationDomain The domain to which the message is sent.
     * @param recipientOracle The address of the oracle on the destination domain.
     * @param gasLimit Gas limit for the message.
     * @param customMetadata Additional metadata to include in the standard hook metadata.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     * @return _gasPayment Payment computed by the registered InterchainGasPaymaster.
     */
    function quoteGasPayment(
        uint32 destinationDomain,
        address recipientOracle,
        uint256 gasLimit,
        bytes calldata customMetadata,
        address source,
        bytes[] calldata payloads
    ) public view returns (uint256) {
        return _quoteGasPayment(
            destinationDomain,
            recipientOracle,
            StandardHookMetadata.formatMetadata(0, gasLimit, msg.sender, customMetadata),
            hook(),
            source,
            payloads
        );
    }

    /**
     * @notice Returns the gas payment required to dispatch a message to the given domain's oracle.
     * @param destinationDomain The domain to which the message is sent.
     * @param recipientOracle The address of the oracle on the destination domain.
     * @param gasLimit Gas limit for the message.
     * @param customMetadata Additional metadata to include in the standard hook metadata.
     * @param customHook Custom hook to be used instead of the one already configured in this client.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     * @return _gasPayment Payment computed by the registered InterchainGasPaymaster.
     */
    function quoteGasPayment(
        uint32 destinationDomain,
        address recipientOracle,
        uint256 gasLimit,
        bytes calldata customMetadata,
        IPostDispatchHook customHook,
        address source,
        bytes[] calldata payloads
    ) public view returns (uint256) {
        return _quoteGasPayment(
            destinationDomain,
            recipientOracle,
            StandardHookMetadata.formatMetadata(0, gasLimit, msg.sender, customMetadata),
            customHook,
            source,
            payloads
        );
    }

    function _quoteGasPayment(
        uint32 destinationDomain,
        address recipientOracle,
        bytes memory hookMetadata,
        IPostDispatchHook customHook,
        address source,
        bytes[] calldata payloads
    ) internal view returns (uint256) {
        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);

        return
            MAILBOX.quoteDispatch(destinationDomain, recipientOracle.toIdentifier(), message, hookMetadata, customHook);
    }

    function _submit(
        uint32 destinationDomain,
        address recipientOracle,
        bytes memory hookMetadata,
        IPostDispatchHook customHook,
        address source,
        bytes[] calldata payloads
    ) internal {
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();

        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);

        MAILBOX.dispatch{ value: msg.value }(
            destinationDomain, recipientOracle.toIdentifier(), message, hookMetadata, customHook
        );
    }
}
