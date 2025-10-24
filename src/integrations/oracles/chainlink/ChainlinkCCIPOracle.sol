// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";

import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../oracles/ChainMap.sol";

import { CCIPReceiver } from "./external/CCIPReceiver.sol";
import { Client } from "./external/Client.sol";
import { IRouterClient } from "./external/interfaces/IRouterClient.sol";

/**
 * @notice Chainlink Cross-Chain Interoperability Protocol
 * Implement interfaces for receiving and sending Chainlink CCIP messages.
 */
contract ChainlinkCCIPOracle is BaseInputOracle, ChainMap, CCIPReceiver {
    using LibAddress for address;

    error NotAllPayloadsValid();
    error RefundFailed();
    error NoReceivers();

    constructor(
        address _owner,
        address router
    ) payable ChainMap(_owner) CCIPReceiver(router) { }

    modifier validatePayloads(
        address source,
        bytes[] calldata payloads
    ) {
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();
        _;
    }

    function refundExcess() internal returns (uint256 refunded) {
        if (address(this).balance > 0) {
            refunded = address(this).balance;
            (bool success,) = msg.sender.call{ value: address(this).balance }("");
            if (!success) revert RefundFailed();
        }
    }

    /**
     * @notice Get the chainlink fee for broadcasting a set of payloads.
     * @dev For multiple destinations this endpoints have to be called individually for each destination.
     */
    function getFee(
        uint64 destinationChainSelector,
        bytes32 receiver,
        bytes calldata extraArgs,
        address source,
        bytes[] calldata payloads,
        address feeToken
    ) external view returns (uint256 fees) {
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encodePacked(receiver), // We will set the receiver in the for loop.
            data: MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: extraArgs,
            feeToken: feeToken
        });
        fees = IRouterClient(getRouter()).getFee(destinationChainSelector, evm2AnyMessage);
    }

    // --- Sending Proofs --- //

    /**
     * @notice Takes proofs that have been marked as valid by a source and submits them to Wormhole for broadcast.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     * @return refund If too much value has been sent, the excess will be returned to msg.sender.
     */
    function submitBatch(
        uint64[] calldata destinationChainSelectors,
        bytes32[] calldata receivers,
        bytes calldata extraArgs,
        address source,
        bytes[] calldata payloads,
        address feeToken
    ) public payable validatePayloads(source, payloads) returns (uint256 refund) {
        _submitBatch(destinationChainSelectors, receivers, extraArgs, source, payloads, feeToken);
        return refundExcess();
    }

    function submit(
        uint64 destinationChainSelector,
        bytes32 receiver,
        bytes calldata extraArgs,
        address source,
        bytes[] calldata payloads,
        address feeToken
    ) public payable validatePayloads(source, payloads) returns (uint256 refund) {
        _submit(destinationChainSelector, receiver, extraArgs, source, payloads, feeToken);
        return refundExcess();
    }

    function _submitBatch(
        uint64[] calldata destinationChainSelectors,
        bytes32[] calldata receivers,
        bytes calldata extraArgs,
        address source,
        bytes[] calldata payloads,
        address feeToken
    ) internal {
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: new bytes(0), // We will set the receiver in the for loop.
            data: MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: extraArgs,
            feeToken: feeToken
        });

        uint256 numDestinationChains = destinationChainSelectors.length;
        if (receivers.length == 0) revert NoReceivers();

        for (uint256 i; i < numDestinationChains; ++i) {
            if (receivers.length > i) evm2AnyMessage.receiver = abi.encodePacked(receivers[i]);
            _submitMessage(destinationChainSelectors[i], evm2AnyMessage, feeToken);
        }
    }

    function _submit(
        uint64 destinationChainSelector,
        bytes32 receiver,
        bytes calldata extraArgs,
        address source,
        bytes[] calldata payloads,
        address feeToken
    ) internal {
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encodePacked(receiver), // We will set the receiver in the for loop.
            data: MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: extraArgs,
            feeToken: feeToken
        });

        _submitMessage(destinationChainSelector, evm2AnyMessage, feeToken);
    }

    // --- Chainlink CCIP Logic --- //

    function _submitMessage(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage memory evm2AnyMessage,
        address feeToken
    ) internal {
        uint256 fees = IRouterClient(getRouter()).getFee(destinationChainSelector, evm2AnyMessage);

        if (feeToken != address(0)) {
            // Collect tokens from caller.
            SafeERC20.safeTransferFrom(IERC20(feeToken), msg.sender, address(this), fees);

            // Approve router client.
            uint256 currentAllowance = IERC20(feeToken).allowance(address(this), getRouter());
            if (currentAllowance < fees) SafeERC20.forceApprove(IERC20(feeToken), getRouter(), type(uint256).max);
        }

        IRouterClient(getRouter())
        .ccipSend{ value: feeToken == address(0) ? fees : 0 }(destinationChainSelector, evm2AnyMessage);
    }

    function _ccipReceive(
        Client.Any2EVMMessage calldata message
    ) internal override {
        bytes32 remoteSenderIdentifier = bytes32(message.sender);

        (bytes32 application, bytes32[] memory payloadHashes) =
            MessageEncodingLib.getHashesOfEncodedPayloads(message.data);

        uint256 remoteChainId = _getMappedChainId(uint256(message.sourceChainSelector));

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i; i < numPayloads; ++i) {
            bytes32 payloadHash = payloadHashes[i];
            _attestations[remoteChainId][remoteSenderIdentifier][application][payloadHash] = true;

            emit OutputProven(remoteChainId, remoteSenderIdentifier, application, payloadHash);
        }
    }
}
