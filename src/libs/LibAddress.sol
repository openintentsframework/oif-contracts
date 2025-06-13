// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title LibAddress
/// @notice A library for converting Ethereum addresses to bytes32 identifiers
/// @dev This library provides utilities for cross-chain address representation
library LibAddress {
    /// @notice Converts an Ethereum address to a bytes32 identifier that can be used across chains
    /// @dev This function pads the address to 32 bytes by casting through uint256
    /// @param addr The address to convert
    /// @return identifier The bytes32 identifier representing the address
    function toIdentifier(address addr) internal pure returns (bytes32 identifier) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @notice Converts a bytes32 identifier back to an Ethereum address
    /// @dev This function truncates the bytes32 to 20 bytes to recover the address
    /// @param identifier The bytes32 identifier to convert
    /// @return addr The Ethereum address recovered from the identifier
    function toAddress(bytes32 identifier) internal pure returns (address addr) {
        return address(uint160(uint256(identifier)));
    }
}