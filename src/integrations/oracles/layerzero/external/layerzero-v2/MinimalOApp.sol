/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "../../../../../libs/LibAddress.sol";
import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin
} from "./interfaces/ILayerZeroEndpointV2.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice This is a minimal implementation of LayerZero OApp contracts
 * https://github.com/LayerZero-Labs/LayerZero-v2/blob/c09287a8b1f236fcc057f474d8a773a0fb7758df/packages/layerzero-v2/evm/oapp/contracts/oapp/OApp.sol
 * to make it ownerless and succinct.
 */
abstract contract MinimalOApp {
    using LibAddress for address;
    using SafeERC20 for IERC20;

    error NotEnoughNative(uint256 msgValue);
    error LzTokenUnavailable();
    error OnlyEndpoint(address addr);

    /// @dev The local LayerZero endpoint associated with the oracle contract.
    ILayerZeroEndpointV2 public immutable endpoint;

    constructor(
        address endpointAddr
    ) {
        endpoint = ILayerZeroEndpointV2(endpointAddr);
    }

    /**
     * @dev Entry point for receiving messages or packets from the endpoint.
     * @param origin The origin information containing the source endpoint and sender address.
     *  - srcEid: The source chain endpoint ID.
     *  - sender: The sender address on the src chain.
     *  - nonce: The nonce of the message.
     * @param guid The unique identifier for the received LayerZero message.
     * @param message The payload of the received message.
     * @param executor The address of the executor for the received message.
     * @param extraData Additional arbitrary data provided by the corresponding executor.
     *
     * @dev Entry point for receiving msg/packet from the LayerZero endpoint.
     */
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) public payable virtual {
        // Ensures that only the endpoint can attempt to lzReceive() messages to this contract.
        if (address(endpoint) != msg.sender) revert OnlyEndpoint(msg.sender);

        // Call the internal OApp implementation of lzReceive.
        _lzReceive(origin, guid, message, executor, extraData);
    }

    /**
     * @dev Internal function to implement lzReceive logic without needing to copy the basic parameter validation.
     */
    function _lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) internal virtual;

    /**
     * @dev Internal function to interact with the LayerZero EndpointV2.send() for sending a message.
     * @param dstEid The destination endpoint ID.
     * @param message The message payload.
     * @param options Additional options for the message.
     * @param fee The calculated LayerZero fee for the message.
     *      - nativeFee: The native fee.
     *      - lzTokenFee: The lzToken fee.
     * @param refundAddress The address to receive any excess fee values sent to the endpoint.
     * @return receipt The receipt for the sent message.
     *      - guid: The unique identifier for the sent message.
     *      - nonce: The nonce of the sent message.
     *      - fee: The LayerZero fee incurred for the message.
     */
    function _lzSend(
        uint32 dstEid,
        address recipientOracle,
        bytes memory message,
        bytes memory options,
        MessagingFee memory fee,
        address refundAddress
    ) internal virtual returns (MessagingReceipt memory receipt) {
        // @dev Push corresponding fees to the endpoint, any excess is sent back to the refundAddress from the
        // endpoint.
        uint256 messageValue = _payNative(fee.nativeFee);
        if (fee.lzTokenFee > 0) _payLzToken(fee.lzTokenFee);

        return endpoint
            // solhint-disable-next-line check-send-result
            .send{ value: messageValue }(
            MessagingParams(dstEid, recipientOracle.toIdentifier(), message, options, fee.lzTokenFee > 0), refundAddress
        );
    }

    /**
     * @dev Internal function to pay the native fee associated with the message.
     * @param nativeFee_ The native fee to be paid.
     * @return nativeFee The amount of native currency paid.
     *
     * @dev If the OApp needs to initiate MULTIPLE LayerZero messages in a single transaction,
     * this will need to be overridden because msg.value would contain multiple lzFees.
     * @dev Should be overridden in the event the LayerZero endpoint requires a different native currency.
     * @dev Some EVMs use an ERC20 as a method for paying transactions/gasFees.
     * @dev The endpoint is EITHER/OR, ie. it will NOT support both types of native payment at a time.
     */
    function _payNative(
        uint256 nativeFee_
    ) internal virtual returns (uint256 nativeFee) {
        if (msg.value != nativeFee_) revert NotEnoughNative(msg.value);
        return nativeFee_;
    }

    /**
     * @dev Internal function to pay the LZ token fee associated with the message.
     * @param lzTokenFee The LZ token fee to be paid.
     *
     * @dev If the caller is trying to pay in the specified lzToken, then the lzTokenFee is passed to the endpoint.
     * @dev Any excess sent, is passed back to the specified refundAddress in the _lzSend().
     */
    function _payLzToken(
        uint256 lzTokenFee
    ) internal virtual {
        // @dev Cannot cache the token because it is not immutable in the endpoint.
        address lzToken = endpoint.lzToken();
        if (lzToken == address(0)) revert LzTokenUnavailable();

        // Pay LZ token fee by sending tokens to the endpoint.
        IERC20(lzToken).safeTransferFrom(msg.sender, address(endpoint), lzTokenFee);
    }

    /**
     * @dev Internal function to interact with the LayerZero EndpointV2.quote() for fee calculation.
     * @param dstEid The destination endpoint ID.
     * @param message The message payload.
     * @param options Additional options for the message.
     * @param payInLzToken Flag indicating whether to pay the fee in LZ tokens.
     * @return fee The calculated MessagingFee for the message.
     *      - nativeFee: The native fee for the message.
     *      - lzTokenFee: The LZ token fee for the message.
     */
    function _quote(
        uint32 dstEid,
        address recipientOracle,
        bytes memory message,
        bytes memory options,
        bool payInLzToken
    ) internal view virtual returns (MessagingFee memory fee) {
        return endpoint.quote(
            MessagingParams(dstEid, recipientOracle.toIdentifier(), message, options, payInLzToken), address(this)
        );
    }
}
