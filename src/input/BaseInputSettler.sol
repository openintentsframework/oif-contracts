// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "../libs/LibAddress.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";

import { IOIFCallback } from "../interfaces/IOIFCallback.sol";
import { IOracle } from "../interfaces/IOracle.sol";

import { AllowOpenType } from "./types/AllowOpenType.sol";
import { MandateOutput } from "./types/MandateOutputType.sol";
import { OrderPurchase, OrderPurchaseType } from "./types/OrderPurchaseType.sol";

/**
 * @title Base Input Settler
 * @notice Defines common logic that can be reused by other input settlers to support a variety of asset management
 * schemes.
 */
abstract contract BaseInputSettler is EIP712 {
    using LibAddress for address;
    using LibAddress for bytes32;

    error AlreadyPurchased();
    error Expired();
    error InvalidPurchaser();
    error InvalidSigner();

    event Finalised(bytes32 indexed orderId, bytes32 solver, bytes32 destination);
    event OrderPurchased(bytes32 indexed orderId, bytes32 solver, bytes32 purchaser);

    uint256 constant DISCOUNT_DENOM = 10 ** 18;

    struct Purchased {
        uint32 lastOrderTimestamp;
        bytes32 purchaser;
    }

    mapping(bytes32 solver => mapping(bytes32 orderId => Purchased)) public purchasedOrders;

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // --- Timestamp Helpers --- //

    /**
     * @param timestamps Array of uint32s.
     * @return timestamp Largest element of timestamps.
     */
    function _maxTimestamp(
        uint32[] calldata timestamps
    ) internal pure returns (uint256 timestamp) {
        timestamp = timestamps[0];

        uint256 numTimestamps = timestamps.length;
        for (uint256 i = 1; i < numTimestamps; ++i) {
            uint32 nextTimestamp = timestamps[i];
            if (timestamp < nextTimestamp) timestamp = nextTimestamp;
        }
    }

    /**
     * @param timestamps Array of uint32s.
     * @return timestamp Smallest element of timestamps.
     */
    function _minTimestamp(
        uint32[] calldata timestamps
    ) internal pure returns (uint256 timestamp) {
        timestamp = timestamps[0];

        uint256 numTimestamps = timestamps.length;
        for (uint256 i = 1; i < numTimestamps; ++i) {
            uint32 nextTimestamp = timestamps[i];
            if (timestamp > nextTimestamp) timestamp = nextTimestamp;
        }
    }

    // --- External Claimant --- //

    /**
     * @notice Check for a signed message by an order owner to allow someone else to redeem an order.
     * @dev See AllowOpenType.sol
     * @param orderId A unique identifier for an order.
     * @param orderOwner Owner of the order, and signer of orderOwnerSignature.
     * @param nextDestination New destination.
     * @param call An external call required by orderOwner.
     * @param orderOwnerSignature EIP712 Signature of AllowOpen by orderOwner.
     */
    function _allowExternalClaimant(
        bytes32 orderId,
        address orderOwner,
        bytes32 nextDestination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) internal view {
        bytes32 digest = _hashTypedData(AllowOpenType.hashAllowOpen(orderId, nextDestination, call));
        bool isValid = SignatureCheckerLib.isValidSignatureNowCalldata(orderOwner, digest, orderOwnerSignature);
        if (!isValid) revert InvalidSigner();
    }

    // --- Order Purchase Helpers --- //

    /**
     * @notice Helper function to get the owner of order incase it may have been bought. In case an order has been
     * bought, and bought in time, the owner will be set to the purchaser. Otherwise it will be set to the solver.
     * @param orderId A unique identifier for an order.
     * @param solver Solver identifier that filled the order.
     * @param timestamps List of timestamps for when the outputs were filled.
     * @return orderOwner Owner of the order.
     */
    function _purchaseGetOrderOwner(
        bytes32 orderId,
        bytes32 solver,
        uint32[] calldata timestamps
    ) internal returns (bytes32 orderOwner) {
        Purchased storage purchaseDetails = purchasedOrders[solver][orderId];
        uint32 lastOrderTimestamp = purchaseDetails.lastOrderTimestamp;
        bytes32 purchaser = purchaseDetails.purchaser;

        if (purchaser != bytes32(0)) {
            // We use the last fill (oldest) to gauge if the order was purchased in time.
            uint256 orderTimestamp = _maxTimestamp(timestamps);
            delete purchaseDetails.lastOrderTimestamp;
            delete purchaseDetails.purchaser;
            // If the timestamp is less than or equal to lastOrderTimestamp, the order was purchased in time.
            if (lastOrderTimestamp <= orderTimestamp) return purchaser;
        }
        return solver;
    }

    /**
     * @notice Helper functions for purchasing orders.
     *  @dev The integrating implementation needs to provide the correct orderId and inputs according to the order.
     * @param orderPurchase Order purchase description signed by solver.
     * @param inputs Order inputs that have to be bought.
     * @param orderSolvedByIdentifier Solver of the order. Is not validated.
     * @param purchaser The new order owner.
     * @param expiryTimestamp Set to ensure if your transaction does not mine quickly, you don't end up purchasing an
     * order that you can not prove OR is outside the timeToBuy window.
     * @param solverSignature EIP712 Signature of OrderPurchase by orderOwner.
     */
    function _purchaseOrder(
        OrderPurchase calldata orderPurchase,
        uint256[2][] calldata inputs,
        bytes32 orderSolvedByIdentifier,
        bytes32 purchaser,
        uint256 expiryTimestamp,
        bytes calldata solverSignature
    ) internal {
        if (purchaser == bytes32(0)) revert InvalidPurchaser();
        if (expiryTimestamp < block.timestamp) revert Expired();

        {
            Purchased storage purchased = purchasedOrders[orderSolvedByIdentifier][orderPurchase.orderId];
            if (purchased.purchaser != bytes32(0)) revert AlreadyPurchased();

            // Reentry protection. Ensure that you can't reenter this contract.
            unchecked {
                // unchecked: uint32(block.timestamp) > timeToBuy => uint32(block.timestamp) - timeToBuy > 0.
                uint32 timeToBuy = orderPurchase.timeToBuy;
                purchased.lastOrderTimestamp =
                    timeToBuy < uint32(block.timestamp) ? uint32(block.timestamp) - timeToBuy : 0;
                purchased.purchaser = purchaser; // This disallows reentries through purchased.purchaser != address(0)
            }
            // We can now make external calls without allowing local reentries into this call.
        }

        {
            address orderSolvedByAddress = orderSolvedByIdentifier.fromIdentifier();
            bytes32 digest = _hashTypedData(OrderPurchaseType.hashOrderPurchase(orderPurchase));
            bool isValid =
                SignatureCheckerLib.isValidSignatureNowCalldata(orderSolvedByAddress, digest, solverSignature);
            if (!isValid) revert InvalidSigner();
        }

        address newDestination = orderPurchase.destination;
        {
            uint256 discount = orderPurchase.discount;
            uint256 numInputs = inputs.length;
            for (uint256 i; i < numInputs; ++i) {
                uint256[2] calldata input = inputs[i];
                uint256 tokenId = input[0];
                uint256 allocatedAmount = input[1];
                uint256 amountAfterDiscount = (allocatedAmount * (DISCOUNT_DENOM - discount)) / DISCOUNT_DENOM;
                // Throws if discount > DISCOUNT_DENOM => DISCOUNT_DENOM - discount < 0;
                SafeTransferLib.safeTransferFrom(
                    EfficiencyLib.asSanitizedAddress(tokenId), msg.sender, newDestination, amountAfterDiscount
                );
            }
            // Emit the event now because of stack issues.
            emit OrderPurchased(orderPurchase.orderId, orderSolvedByIdentifier, purchaser);
        }
        {
            bytes calldata call = orderPurchase.call;
            if (call.length > 0) IOIFCallback(newDestination).orderFinalised(inputs, call);
        }
    }
}
