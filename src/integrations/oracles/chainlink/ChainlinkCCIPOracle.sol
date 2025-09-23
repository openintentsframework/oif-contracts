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
 * Implement interfaces for receving and sending Chainlink CCIP messages.
 */
contract ChainlinkCCIPOracle is BaseInputOracle, ChainMap, CCIPReceiver {
    using LibAddress for address;

    error NotAllPayloadsValid();
    error RefundFailed();

    constructor(address _owner, address router) payable ChainMap(_owner) CCIPReceiver(router) { }

    // --- Sending Proofs --- //

    /**
     * @notice Takes proofs that have been marked as valid by a source and submits them to Wormhole for broadcast.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     * @return refund If too much value has been sent, the excess will be returned to msg.sender.
     */
    function submit(
        uint64[] calldata destinationChainSelectors,
        bytes32[] calldata receivers,
        bytes calldata extraArgs,
        address source,
        bytes[] calldata payloads,
        address feeToken
    ) public payable returns (uint256 refund) {
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();
        return _submits(destinationChainSelectors, receivers, extraArgs, source, payloads, feeToken);
    }

    // --- Wormhole Logic --- //

    function _submits(
        uint64[] calldata destinationChainSelectors,
        bytes32[] calldata receivers,
        bytes calldata extraArgs,
        address source,
        bytes[] calldata payloads,
        address feeToken
    ) internal returns (uint256 refund) {
        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: new bytes(0), // We will set the receiver in the for loop.
            data: message,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: extraArgs,
            feeToken: feeToken
        });

        // TODO: Should chain ids be translated from chainlink to erc20?
        uint256 numDestinationChains = destinationChainSelectors.length;
        uint256 numReceivers = receivers.length;
        // todo: numReceivers != 0;

        uint256 nativeSpent = 0;
        for (uint256 i; i < numDestinationChains; ++i) {
            if (numReceivers >= i) evm2AnyMessage.receiver = abi.encode(receivers[i]);
            nativeSpent += _submit(destinationChainSelectors[i], evm2AnyMessage, feeToken);
        }
        // Refund excess.
        if (msg.value > nativeSpent) {
            refund = msg.value - nativeSpent;
            (bool success,) = msg.sender.call{ value: refund }("");
            if (!success) revert RefundFailed();
        }
    }

    function _submit(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage memory evm2AnyMessage,
        address feeToken
    ) internal returns (uint256 nativeFees) {
        uint256 fees = IRouterClient(i_ccipRouter).getFee(destinationChainSelector, evm2AnyMessage);
        nativeFees = feeToken == address(0) ? fees : 0;

        if (feeToken != address(0)) {
            // Collect tokens from caller.
            SafeERC20.safeTransferFrom(IERC20(feeToken), msg.sender, address(this), fees);

            // Aprove router client.
            uint256 currentAllowance = IERC20(feeToken).allowance(address(this), i_ccipRouter);
            if (currentAllowance < fees) SafeERC20.forceApprove(IERC20(feeToken), i_ccipRouter, type(uint256).max);
        }

        IRouterClient(i_ccipRouter).ccipSend{ value: nativeFees }(destinationChainSelector, evm2AnyMessage);
    }

    function _ccipReceive(
        Client.Any2EVMMessage calldata message
    ) internal override {
        // TODO: Verify when more than 32 bytes are used.
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
