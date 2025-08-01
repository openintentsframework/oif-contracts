// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title LibAddress
/// @notice Library for address-related utility functions
/// @dev Provides functions for converting addresses to cross-chain identifiers
library LibAddress {
    /// @notice Converts an Ethereum address to a bytes32 identifier that can be used across chains
    /// @dev Uses the address's numeric value as a bytes32 identifier by casting type in-place.
    /// @param addr The address to convert
    /// @return identifier The bytes32 identifier representation of the address
    function toIdentifier(
        address addr
    ) internal pure returns (bytes32 identifier) {
        assembly ("memory-safe") {
            identifier := addr
        }
    }

    /// @notice Converts a bytes32 identifier back to an Ethereum address
    /// @dev Reverses the toIdentifier operation by casting through uint256 and uint160
    /// @param identifier The bytes32 identifier to convert
    /// @return _ The address representation of the identifier
    function fromIdentifier(
        bytes32 identifier
    ) internal pure returns (address) {
        return address(uint160(uint256(identifier)));
    }

    /// @notice Converts a uint256 identifier back to an Ethereum address
    /// @dev Reverses the toIdentifier operation by casting through uint160
    /// @param identifier The uint256 identifier to convert
    /// @return _ The address representation of the identifier
    function fromIdentifier(
        uint256 identifier
    ) internal pure returns (address) {
        return address(uint160(identifier));
    }
}
