// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Library to extract the fields of serialized output data to their respective types.
 * @dev This library provides low-level parsing functions for output data that has been encoded
 * using a specific byte layout. The encoding scheme uses 2 bytes long length identifiers,
 * which means neither call nor context data can exceed 65,535 bytes.
 *
 * @dev Bytes Layout
 * The serialized output follows this exact byte layout:
 *
 * FILL_DEADLINE           0               (6 bytes)   - uint48 timestamp
 * + ORACLE                6               (32 bytes)  - bytes32 oracle address
 * + SETTLER               38              (32 bytes)  - bytes32 settler address
 * + CHAIN_ID              70              (32 bytes)  - uint256 chain identifier
 * + TOKEN                 102             (32 bytes)  - bytes32 token address
 * + AMOUNT                134             (32 bytes)  - uint256 amount
 * + RECIPIENT             166             (32 bytes)  - bytes32 recipient address
 * + CALL_LENGTH           198             (2 bytes)   - uint16 call data length
 * + CALL                  200             (LENGTH bytes) - call data payload
 * + CONTEXT_LENGTH        200+RC_LENGTH   (2 bytes)   - uint16 context data length
 * + CONTEXT               202+RC_LENGTH   (LENGTH bytes) - context data payload
 *
 */
library OutputFillLib {
    /**
     * @notice Loads the fill deadline from the output.
     * @param output Serialised output.
     * @return _fillDeadline Fill deadline associated with the output.
     */
    function fillDeadline(
        bytes calldata output
    ) internal pure returns (uint48 _fillDeadline) {
        assembly ("memory-safe") {
            _fillDeadline := shr(208, calldataload(add(output.offset, 0x00)))
        }
    }

    /**
     * @notice Loads the oracle from the output.
     * @param output Serialised output.
     * @return _oracle Oracle associated with the output.
     */
    function oracle(
        bytes calldata output
    ) internal pure returns (bytes32 _oracle) {
        assembly ("memory-safe") {
            _oracle := calldataload(add(output.offset, 0x06))
        }
    }

    /**
     * @notice Loads the settler from the output.
     * @param output Serialised output.
     * @return _settler Settler associated with the output.
     */
    function settler(
        bytes calldata output
    ) internal pure returns (bytes32 _settler) {
        assembly ("memory-safe") {
            _settler := calldataload(add(output.offset, 0x26))
        }
    }

    /**
     * @notice Loads the chain ID from the output.
     * @param output Serialised output.
     * @return _chainId Chain ID associated with the output.
     */
    function chainId(
        bytes calldata output
    ) internal pure returns (uint256 _chainId) {
        assembly ("memory-safe") {
            _chainId := calldataload(add(output.offset, 0x46))
        }
    }

    /**
     * @notice Loads the token from the output.
     * @param output Serialised output.
     * @return _token Token associated with the output.
     */
    function token(
        bytes calldata output
    ) internal pure returns (bytes32 _token) {
        assembly ("memory-safe") {
            _token := calldataload(add(output.offset, 0x66))
        }
    }

    /**
     * @notice Loads the amount from the output.
     * @param output Serialised output.
     * @return _amount Amount associated with the output.
     */
    function amount(
        bytes calldata output
    ) internal pure returns (uint256 _amount) {
        assembly ("memory-safe") {
            _amount := calldataload(add(output.offset, 0x86))
        }
    }

    /**
     * @notice Loads the recipient from the output.
     * @param output Serialised output.
     * @return _recipient Recipient associated with the output.
     */
    function recipient(
        bytes calldata output
    ) internal pure returns (bytes32 _recipient) {
        assembly ("memory-safe") {
            _recipient := calldataload(add(output.offset, 0xa6))
        }
    }

    /**
     * @notice Loads the callback data from the output.
     * @param output Serialised output.
     * @return _callbackData Callback data associated with the output.
     * @dev The callback data is variable-length and follows the fixed header fields.
     * Its length is stored as a 2-byte uint16 at offset 198.
     */
    function callbackData(
        bytes calldata output
    ) internal pure returns (bytes calldata _callbackData) {
        assembly ("memory-safe") {
            let length := shr(240, calldataload(add(output.offset, 0xc6)))

            _callbackData.offset := add(output.offset, 0xc8)
            _callbackData.length := length
        }
    }

    /**
     * @notice Loads the context data from the output.
     * @param output Serialised output.
     * @return _contextData Context data associated with the output.
     * @dev The context data is variable-length and follows the callback data.
     * Its length is stored as a 2-byte uint16 after the callback data.
     */
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
