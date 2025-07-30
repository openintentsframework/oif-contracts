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

    /**
     * @notice Given abi.encoded bytes[] inside a bytes calldata, returns the length of bytes[]
     * @param _bytes Calldata reference to encoded bytes[]
     * @return length of bytes[]
     */
    function getLengthOfBytesArray(
        bytes calldata _bytes
    ) internal pure returns (uint256 length) {
        assembly ("memory-safe") {
            let pointerOfBytesArray := add(_bytes.offset, calldataload(_bytes.offset))
            length := calldataload(pointerOfBytesArray)
        }
    }

    /**
     * @notice Given calldata bytes of bytes[], slices a bytes array by the offset.
     * @dev Does not validate that the slice won't go out of calldata.
     * @param _bytes Calldata reference to encoded bytes[]
     * @param offset index to select the bytes at
     * @return res bytes of bytes[] indexed at offset.
     */
    function getBytesOfArray(bytes calldata _bytes, uint256 offset) internal pure returns (bytes calldata res) {
        assembly ("memory-safe") {
            let pointerOfBytesArray := add(_bytes.offset, calldataload(_bytes.offset))
            let pointerOfBytes :=
                add(add(pointerOfBytesArray, calldataload(add(pointerOfBytesArray, mul(add(offset, 1), 0x20)))), 0x20)
            res.offset := add(pointerOfBytes, 0x20)
            res.length := calldataload(pointerOfBytes)
        }
    }
}
