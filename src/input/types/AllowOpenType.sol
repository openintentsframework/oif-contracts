// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Signed struct
struct AllowOpen {
    bytes32 orderId;
    bytes32 destination;
    bytes call;
}

/**
 * @notice Helper library for the Allow Open type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library AllowOpenType {
    bytes constant ALLOW_OPEN_TYPE_STUB = bytes("AllowOpen(bytes32 orderId,bytes32 destination,bytes call)");

    bytes32 constant ALLOW_OPEN_TYPE_HASH = keccak256(ALLOW_OPEN_TYPE_STUB);

    /**
     * @notice Hashes an AllowOpen struct.
     * @param orderId The unique identifier for the order.
     * @param destination New destination for the order.
     * @param call If set (!= "0x"), will execute an external orderFinalised call.
     * @return digest of hashAllowOpen.
     */
    function hashAllowOpen(
        bytes32 orderId,
        bytes32 destination,
        bytes calldata call
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(ALLOW_OPEN_TYPE_HASH, orderId, destination, keccak256(call)));
    }
}
