// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/**
 * @notice Signed struct
 */
struct OrderPurchase {
    bytes32 orderId;
    /// @dev unlike other destinations, this needs to be an external address
    address destination;
    bytes call;
    uint64 discount;
    uint32 timeToBuy;
}

/**
 * @notice Helper library for the Order Purchase type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library OrderPurchaseType {
    bytes constant ORDER_PURCHASE_TYPE_STUB =
        bytes("OrderPurchase(bytes32 orderId,address destination,bytes call,uint64 discount,uint32 timeToBuy)");

    bytes32 constant ORDER_PURCHASE_TYPE_HASH = keccak256(ORDER_PURCHASE_TYPE_STUB);

    function hashOrderPurchase(
        OrderPurchase calldata orderPurchase
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_PURCHASE_TYPE_HASH,
                orderPurchase.orderId,
                orderPurchase.destination,
                keccak256(orderPurchase.call),
                orderPurchase.discount,
                orderPurchase.timeToBuy
            )
        );
    }
}
