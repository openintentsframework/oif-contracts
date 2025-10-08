/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";

import { AxelarExecutable } from "./external/axelar/executable/AxelarExecutable.sol";

import { IAxelarGasService } from "./external/axelar/interfaces/IAxelarGasService.sol";
import { StringToAddress } from "./external/axelar/libs/AddressString.sol";

/**
 * @notice Axelar Oracle.
 * Implements a transparent oracle that allows both sending and receiving messages along with
 * exposing the hash of received messages.
 */
contract AxelarOracle is BaseInputOracle, AxelarExecutable {
    using LibAddress for address;
    using StringToAddress for string;

    error NotAllPayloadsValid();
    error EmptyPayloadsNotAllowed();

    // A constant is used to get the chain id from the source chain name
    uint256 private constant BITS_TO_SHIFT_FOR_CHAIN_ID = 224; // 256 - 32

    IAxelarGasService public immutable gasService;

    constructor(address gateway_, address gasService_) AxelarExecutable(gateway_) {
        if (gasService_ == address(0)) revert InvalidAddress();

        gasService = IAxelarGasService(gasService_);
    }

    // --- Sending Proofs --- //

    /**
     * @notice Takes proofs that have been marked as valid by a source and submits them to Axelar for broadcast.
     * @param destinationChain Name of the destination chain.
     * @param destinationAddress Address of the destination contract.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     */
    function submit(
        string calldata destinationChain,
        string calldata destinationAddress,
        address source,
        bytes[] calldata payloads
    ) public payable {
        _submit(destinationChain, destinationAddress, source, payloads);
    }

    // --- Axelar Logic --- //

    /**
     * @notice Takes proofs that have been marked as valid by a source and submits them to Axelar for broadcast.
     * @dev A payment is required to send a cross-chain message; it can be made on either the source or destination
     * chain, and any excess amount is refunded to msg.sender.
     * @param destinationChain Name of the destination chain.
     * @param destinationAddress Address of the destination contract.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     */
    function _submit(
        string calldata destinationChain,
        string calldata destinationAddress,
        address source,
        bytes[] calldata payloads
    ) internal {
        if (source == address(0)) revert InvalidAddress();
        if (payloads.length == 0) revert EmptyPayloadsNotAllowed();

        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();

        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);

        gasService.payNativeGasForContractCall{ value: msg.value }(
            address(this), destinationChain, destinationAddress, message, msg.sender
        );

        gateway().callContract(destinationChain, destinationAddress, message);
    }

    /**
     * @notice Takes a Axelar message and stores attestations of the contained payloads.
     * @dev This function is called with source chain name, but we need the chain id to store the attestations.
     * Therefore, we hash the source chain name and shift the bits to get the chain id.
     * However, same chain Ids may be assigned to different chain names, which can lead to collisions.
     * @param sourceChain Name of the source chain.
     * @param sourceAddress Address of the sender on the source chain.
     * @param payload Payload of the message.
     */
    function _execute(
        bytes32,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal override {
        bytes32 hashedSourceChain = keccak256(abi.encodePacked(sourceChain));
        uint32 sourceChainId = uint32(uint256(hashedSourceChain) >> BITS_TO_SHIFT_FOR_CHAIN_ID);

        bytes32 sourceSender = sourceAddress.toAddress().toIdentifier();

        (bytes32 application, bytes32[] memory payloadHashes) = MessageEncodingLib.getHashesOfEncodedPayloads(payload);

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i; i < numPayloads; ++i) {
            bytes32 payloadHash = payloadHashes[i];
            _attestations[sourceChainId][sourceSender][application][payloadHash] = true;

            emit OutputProven(sourceChainId, sourceSender, application, payloadHash);
        }
    }
}
