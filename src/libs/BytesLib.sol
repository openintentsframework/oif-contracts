// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @title Library for Bytes Manipulation
/// Based on Gonçalo Sá's BytesLib
library BytesLib {
    /**
     * @notice Takes a calldata reference, and decodes a bytes based on offset.
     * @param _bytes Calldata reference.
     * @param offset Offset for bytes array.
     */
    function toBytes(bytes calldata _bytes, uint256 offset) internal pure returns (bytes calldata res) {
        assembly ("memory-safe") {
            let lengthPtr := add(_bytes.offset, calldataload(add(_bytes.offset, offset)))
            res.offset := add(lengthPtr, 0x20)
            res.length := calldataload(lengthPtr)
        }
    }
}
