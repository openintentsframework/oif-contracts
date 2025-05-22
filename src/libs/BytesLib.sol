// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @title Library for Bytes Manipulation
/// Based on Gonçalo Sá's BytesLib - but updated and heavily edited
library BytesLib {
    function toBytes(bytes calldata _bytes, uint256 arg) internal pure returns (bytes calldata res) {
        assembly {
            let lengthPtr := add(_bytes.offset, calldataload(add(_bytes.offset, mul(0x20, arg))))
            res.offset := add(lengthPtr, 0x20)
            res.length := calldataload(lengthPtr)
        }
    }
}
