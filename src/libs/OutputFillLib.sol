// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library OutputFillLib {
    function fillDeadline(
        bytes calldata output
    ) internal pure returns (uint48 fillDeadline) {
        assembly ("memory-safe") {
            fillDeadline := shr(208, calldataload(add(output.offset, 0x00)))
        }
    }

    function oracle(
        bytes calldata output
    ) internal pure returns (bytes32 oracle) {
        assembly ("memory-safe") {
            oracle := calldataload(add(output.offset, 0x06))
        }
    }

    function settler(
        bytes calldata output
    ) internal pure returns (bytes32 settler) {
        assembly ("memory-safe") {
            settler := calldataload(add(output.offset, 0x26))
        }
    }

    function chainId(
        bytes calldata output
    ) internal pure returns (uint256 chainId) {
        assembly ("memory-safe") {
            chainId := calldataload(add(output.offset, 0x46))
        }
    }

    function token(
        bytes calldata output
    ) internal pure returns (bytes32 token) {
        assembly ("memory-safe") {
            token := calldataload(add(output.offset, 0x66))
        }
    }

    function amount(
        bytes calldata output
    ) internal pure returns (uint256 amount) {
        assembly ("memory-safe") {
            amount := calldataload(add(output.offset, 0x86))
        }
    }

    function recipient(
        bytes calldata output
    ) internal pure returns (bytes32 recipient) {
        assembly ("memory-safe") {
            recipient := calldataload(add(output.offset, 0xa6))
        }
    }

    function callbackData(
        bytes calldata output
    ) internal pure returns (bytes calldata _callbackData) {
        assembly ("memory-safe") {
            let length := shr(240, calldataload(add(output.offset, 0xc6)))

            _callbackData.offset := add(output.offset, 0xc8)
            _callbackData.length := length
        }
    }

    function contextData(
        bytes calldata output
    ) internal pure returns (bytes calldata _contextData) {
        assembly ("memory-safe") {
            let callbackDataLength := shr(240, calldataload(add(output.offset, 0xc6)))
            let contextLengthOffset := add(add(output.offset, 0xc8), callbackDataLength)
            let contextLength := shr(240, calldataload(contextLengthOffset))

            _contextData.offset := add(contextLengthOffset, 0x02)
            _contextData.length := contextLength
        }
    }
}
