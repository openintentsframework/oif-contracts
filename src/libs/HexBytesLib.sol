// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { Bytes } from "@openzeppelin/contracts/utils/Bytes.sol";

/// @title HexBytes
/// @notice Utility functions for working with hex-encoded data in bytes and string form.
/// @dev Provides helpers for parsing hex strings and matching/slicing byte arrays.
library HexBytes {
    error InvalidHexChar();
    error InvalidHexBytes32Length();

    /// @notice Converts a single ASCII hex character to its numeric value.
    /// @dev Accepts characters in the ranges '0'-'9', 'a'-'f', and 'A'-'F'; reverts with `InvalidHexChar` otherwise.
    /// @param c The ASCII code of the hex character.
    /// @return The numeric value corresponding to `c` in the range [0, 15].
    function fromHexChar(
        uint8 c
    ) internal pure returns (uint8) {
        if (c >= 48 && c <= 57) {
            // '0' - '9'
            return c - 48;
        }
        c |= 0x20; // Convert all uppercase letters into lowercase.
        if (c >= 97 && c <= 102) {
            // 'a' - 'f'
            return c - 87;
        }
        revert InvalidHexChar();
    }

    /// @notice Parses a hex string into a `bytes32` value.
    /// @dev
    /// - Accepts an optional `"0x"` / `"0X"` prefix.
    /// - Requires exactly 64 hex characters after the optional prefix; otherwise reverts with `InvalidHexBytes32Length`.
    /// - Reverts with `InvalidHexChar` if any character is not a valid hex digit.
    /// @param str The hex string to parse.
    /// @return result The parsed `bytes32` value.
    function hexStringToBytes32(
        string memory str
    ) internal pure returns (bytes32 result) {
        bytes memory s = bytes(str);
        uint256 start = 0;
        // Optional 0x / 0X prefix.
        if (s.length >= 2 && s[0] == "0" && ((s[1] | 0x20) == "x")) start = 2;
        require(s.length == start + 64, InvalidHexBytes32Length());
        
        for (uint256 i = 0; i < 32; ++i) {
            uint8 high = fromHexChar(uint8(s[start + 2 * i])); // first hex char
            uint8 low = fromHexChar(uint8(s[start + 2 * i + 1])); // second hex char
            result |= bytes32(uint256(uint8((high << 4) | low)) << (248 - i * 8)); // Combine without overwriting
        }
    }

    /// @notice Returns a slice of `data` starting at `start` with length `len`.
    /// @dev Thin wrapper around OpenZeppelin `Bytes.slice` that uses `(start, len)` instead of `(start, end)`.
    /// @param data The source byte array.
    /// @param start The starting index in `data` (inclusive).
    /// @param len The number of bytes to include in the returned slice.
    /// @return A new bytes array containing `len` bytes from `data` starting at `start`.
    function sliceFromBytes(
        bytes memory data,
        uint256 start,
        uint256 len
    ) internal pure returns (bytes memory) {
        // `Bytes.slice` expects a start index and an end index (exclusive),
        // while this helper takes a start index and a length.
        // Convert (start, len) into (start, start + len).
        return Bytes.slice(data, start, start + len);
    }

    /// @notice Checks whether `subject` has `prefix` starting at index `start`.
    /// @dev Returns `false` if `start + prefix.length` exceeds `subject.length`.
    /// @dev This function is inspired by https://github.com/Vectorized/solady/blob/cbcfe0009477aa329574f17e8db0a05703bb8bdd/src/utils/LibBytes.sol#L382-L395.
    /// @param subject The byte array to search within.
    /// @param prefix The prefix to compare against.
    /// @param start The starting index in `subject` at which to compare `prefix`.
    /// @return result `true` if `subject[start : start + prefix.length]` equals `prefix`, otherwise `false`.
    function hasPrefix(
        bytes memory subject, 
        bytes memory prefix, 
        uint256 start
    ) 
        internal 
        pure 
        returns (bool result) 
    {
        assembly ("memory-safe") {
            let n := mload(prefix)
            let sLen := mload(subject)
            
            // Calculate where the data starts in memory:
            // subject pointer + 32 bytes (length) + start index
            let subjectPtr := add(add(subject, 0x20), start)
            
            // Compare the hash of the prefix to the hash of the slice of the subject
            // We read 'n' bytes from the calculated subjectPtr
            let t := eq(
                keccak256(subjectPtr, n), 
                keccak256(add(prefix, 0x20), n)
            )
            
            // Calculate if the prefix goes out of bounds of the subject
            // end = start + n
            let end := add(start, n)
            
            // Logic: Is the end index > subject length?
            // If end < start, it means we had an integer overflow (unlikely but safe to check)
            let isOutOfBounds := or(lt(end, start), gt(end, sLen))
            
            // Final Result:
            // Returns true ONLY if: (Not Out of Bounds) AND (Hashes Match)
            // lt(isOutOfBounds, t) works because:
            // if outOfBounds (1) and match (1) -> 1 < 1 is False (Safe)
            // if not outOfBounds (0) and match (1) -> 0 < 1 is True (Success)
            result := lt(isOutOfBounds, t)
        }
    }
}
