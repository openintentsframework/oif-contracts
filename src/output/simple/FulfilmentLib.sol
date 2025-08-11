// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Library to extract and parse order fulfillment context data.
 * @dev This library provides low-level parsing functions for context data that encodes
 * different order types and their associated parameters. The context data is used to
 * determine order-specific logic and compute the final amount for order fulfillment.
 *
 * @dev Order Type Context Layout
 * The context data encodes different order types with different fixed-length layouts.
 *
 * Limit Order - Length: 1 byte
 * ORDER_TYPE           0               (1 byte)    - bytes1: 0x00
 *
 * Non Exclusive Dutch Auction - Length: 41 bytes
 * ORDER_TYPE           0               (1 byte)    - bytes1: 0x01
 * + START_TIME         1               (4 bytes)   - uint32: auction start timestamp
 * + STOP_TIME          5               (4 bytes)   - uint32: auction stop timestamp
 * + SLOPE              9               (32 bytes)  - uint256: price decay slope
 *
 * Exclusive Limit Order - Length: 37 bytes
 * ORDER_TYPE           0               (1 byte)    - bytes1: 0xe0
 * + EXCLUSIVE_FOR      1               (32 bytes)  - bytes32: exclusive solver address
 * + START_TIME         33              (4 bytes)   - uint32: order start timestamp
 *
 * Exclusive Dutch Auction - Length: 73 bytes
 * ORDER_TYPE           0               (1 byte)    - bytes1: 0xe1
 * + EXCLUSIVE_FOR      1               (32 bytes)  - bytes32: exclusive solver address
 * + START_TIME         33              (4 bytes)   - uint32: auction start timestamp
 * + STOP_TIME          37              (4 bytes)   - uint32: auction stop timestamp
 * + SLOPE              41              (32 bytes)  - uint256: price decay slope
 */
library FulfilmentLib {
    /// @dev Order type for standard limit orders
    bytes1 constant LIMIT_ORDER = 0x00;
    /// @dev Order type for non exclusive Dutch auction orders
    bytes1 constant DUTCH_AUCTION = 0x01;
    /// @dev Order type for exclusive limit orders
    bytes1 constant EXCLUSIVE_LIMIT_ORDER = 0xe0;
    /// @dev Order type for exclusive Dutch auction orders
    bytes1 constant EXCLUSIVE_DUTCH_AUCTION = 0xe1;

    /// @dev Invalid context data length
    error InvalidContextDataLength();

    /**
     * @notice Extracts the order type from the context data.
     * @param contextData Serialized context data containing order information.
     * @return _orderType The order type identifier (0x00, 0x01, 0xe0, or 0xe1).
     */
    function orderType(
        bytes calldata contextData
    ) internal pure returns (bytes1 _orderType) {
        assembly ("memory-safe") {
            _orderType := calldataload(contextData.offset)
        }
    }

    /**
     * @notice Extracts Dutch auction parameters from context data.
     * @param contextData Serialized context data for a Dutch auction order (type 0x01).
     * @return startTime Auction start timestamp.
     * @return stopTime Auction stop timestamp.
     * @return slope Price decay slope for the auction.
     */
    function getDutchAuctionData(
        bytes calldata contextData
    ) internal pure returns (uint32 startTime, uint32 stopTime, uint256 slope) {
        assembly ("memory-safe") {
            startTime := shr(224, calldataload(add(contextData.offset, 0x01))) // bytes[1:5]
            stopTime := shr(224, calldataload(add(contextData.offset, 0x05))) // bytes[5:9]
            slope := calldataload(add(contextData.offset, 0x09)) // bytes[9:41]
        }
    }

    /**
     * @notice Extracts exclusive limit order parameters from context data.
     * @param contextData Serialized context data for an exclusive limit order (type 0xe0).
     * @return exclusiveFor Address of the exclusive solver for this order.
     * @return startTime Order start timestamp.
     */
    function getExclusiveLimitOrderData(
        bytes calldata contextData
    ) internal pure returns (bytes32 exclusiveFor, uint32 startTime) {
        assembly ("memory-safe") {
            exclusiveFor := calldataload(add(contextData.offset, 0x01)) // bytes[1:33]
            startTime := shr(224, calldataload(add(contextData.offset, 0x21))) // bytes[33:37]
        }
    }

    /**
     * @notice Extracts exclusive Dutch auction parameters from context data.
     * @param contextData Serialized context data for an exclusive Dutch auction order (type 0xe1).
     * @return exclusiveFor Address of the exclusive solver for this order.
     * @return startTime Auction start timestamp.
     * @return stopTime Auction stop timestamp.
     * @return slope Price decay slope for the auction.
     */
    function getExclusiveDutchAuctionData(
        bytes calldata contextData
    ) internal pure returns (bytes32 exclusiveFor, uint32 startTime, uint32 stopTime, uint256 slope) {
        assembly ("memory-safe") {
            exclusiveFor := calldataload(add(contextData.offset, 0x01)) // bytes[1:33]
            startTime := shr(224, calldataload(add(contextData.offset, 0x21))) // bytes[33:37]
            stopTime := shr(224, calldataload(add(contextData.offset, 0x25))) // bytes[37:41]
            slope := calldataload(add(contextData.offset, 0x29)) // bytes[41:73]
        }
    }
}
