// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { Bytes } from "@openzeppelin/contracts/utils/Bytes.sol";

/**
 * @title HexBytes
 * @dev Provides helpers for parsing hex bytes32 in form of bytes and matching/slicing byte arrays.
 */
library HexBytes {
    error InvalidHexChar();
    error InvalidHexBytesLength();
    error InvalidHexBytes32Length();

    /**
     * @notice Converts a single ASCII hex character to its numeric value.
     * @dev Accepts characters in the ranges '0'-'9', 'a'-'f', and 'A'-'F'; reverts with `InvalidHexChar` otherwise.
     * @param c The ASCII code of the hex character.
     * @return The numeric value corresponding to `c` in the range [0, 15].
     */
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

    /**
     * @notice Parses a hex string into a `bytes32` value.
     * @dev
     * - Accepts an optional `"0x"` / `"0X"` prefix.
     * - Requires exactly 64 hex characters after the optional prefix; otherwise reverts with
     *   `InvalidHexBytes32Length`.
     * - Reverts with `InvalidHexChar` if any character is not a valid hex digit.
     * @param hexBytes32 The hex bytes32 in form of bytes to parse.
     * @return result The parsed `bytes32` value.
     */
    function hexBytesToBytes32(
        bytes memory hexBytes32
    ) internal pure returns (bytes32 result) {
        uint256 start = 0;
        // Optional 0x / 0X prefix.
        if (hexBytes32.length >= 2 && hexBytes32[0] == "0" && ((hexBytes32[1] | 0x20) == "x")) start = 2;
        require(hexBytes32.length == start + 64, InvalidHexBytes32Length());

        for (uint256 i = 0; i < 32; ++i) {
            uint8 high = fromHexChar(uint8(hexBytes32[start + 2 * i])); // first hex char
            uint8 low = fromHexChar(uint8(hexBytes32[start + 2 * i + 1])); // second hex char
            result |= bytes32(uint256(uint8((high << 4) | low)) << (248 - i * 8)); // Combine without overwriting
        }
    }

    /**
     * @notice Parses a hex string into raw bytes.
     * @dev
     * - Accepts an optional `"0x"` / `"0X"` prefix.
     * - Requires an even number of hex characters after the optional prefix; otherwise reverts with
     *   `InvalidHexBytesLength`.
     * - Reverts with `InvalidHexChar` if any character is not a valid hex digit.
     * @param hexBytes The hex bytes in form of bytes to parse.
     * @return result The parsed bytes.
     */
    function hexBytesToBytes(
        bytes memory hexBytes
    ) internal pure returns (bytes memory result) {
        uint256 start = 0;
        // Optional 0x / 0X prefix.
        if (hexBytes.length >= 2 && hexBytes[0] == "0" && ((hexBytes[1] | 0x20) == "x")) start = 2;

        uint256 n = hexBytes.length - start;
        require(n % 2 == 0, InvalidHexBytesLength());

        uint256 outLen = n / 2;
        result = new bytes(outLen);
        for (uint256 i = 0; i < outLen; ++i) {
            uint8 high = fromHexChar(uint8(hexBytes[start + 2 * i]));
            uint8 low = fromHexChar(uint8(hexBytes[start + 2 * i + 1]));
            result[i] = bytes1((high << 4) | low);
        }
    }

    /**
     * @notice Returns a slice of `data` starting at `start` with length `len`.
     * @dev Thin wrapper around OpenZeppelin `Bytes.slice` that uses `(start, len)` instead of `(start, end)`.
     * @param data The source byte array.
     * @param start The starting index in `data` (inclusive).
     * @param len The number of bytes to include in the returned slice.
     * @return A new bytes array containing `len` bytes from `data` starting at `start`.
     */
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
}
