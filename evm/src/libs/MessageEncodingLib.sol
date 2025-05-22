// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Library to aid in encoding a series of payloads and decoding a series of payloads.
 * @dev The library does not understand the payloads. Likewise, when parsed the payloads are never used but their hashes
 * are.
 * The library works with uint16 sizes, as a result the maximum number of payloads in a single message is 65'535
 * and the maximum number of bytes in a payload is 65'535.
 *
 * --- Data Structure ---
 *
 *  Common Structure (Repeated 0 times)
 *      SENDER_IDENTIFIER       0       (32 bytes)
 *      + NUM_PAYLOADS          32      (2 bytes)
 *
 *  Payloads (repeated NUM_PAYLOADS times)
 *      PAYLOAD_LENGTH          M_i+0   (2 bytes3)
 *      PAYLOAD                 M_i+2   (PAYLOAD_LENGTH bytes)
 *
 * where M_i = the byte offset of the ith payload, calculated as the sum of previous payload lengths plus their 2-byte
 * size prefixes, starting from byte 34 (32 + 2)
 */
library MessageEncodingLib {
    error TooLargePayload(uint256 size);
    error TooManyPayloads(uint256 size);

    /**
     * @notice Encodes a number of payloads into a single message prepended as reported by an application.
     */
    function encodeMessage(
        bytes32 application,
        bytes[] calldata payloads
    ) internal pure returns (bytes memory encodedPayload) {
        uint256 numPayloads = payloads.length;
        if (numPayloads > type(uint16).max) revert TooManyPayloads(numPayloads);

        // Set the number of outputs as first 2 bytes. This aids implementations which may not have easy access to data
        // size.
        encodedPayload = bytes.concat(application, bytes2(uint16(numPayloads)));
        for (uint256 i; i < numPayloads; ++i) {
            bytes calldata payload = payloads[i];
            // Check if length of payload is within message constraints.
            uint256 payloadLength = payload.length;
            if (payloadLength > type(uint16).max) revert TooLargePayload(payloadLength);
            encodedPayload = abi.encodePacked(encodedPayload, uint16(payloadLength), payload);
        }
    }

    /**
     * @dev Hashes payloads to reduce memory expansion costs.
     */
    function decodeMessage(
        bytes calldata encodedPayload
    ) internal pure returns (bytes32 application, bytes32[] memory payloadHashes) {
        unchecked {
            assembly ("memory-safe") {
                // Load the identifier as the first 32 bytes of the payload. This is equivalent to
                // identifier = bytes32(encodedPayload[0:32]);
                application := calldataload(encodedPayload.offset)
            }
            uint256 numPayloads = uint256(uint16(bytes2(encodedPayload[32:34])));

            payloadHashes = new bytes32[](numPayloads);
            uint256 pointer = 34;
            for (uint256 index = 0; index < numPayloads; ++index) {
                // Don't allow overflows here. Otherwise you could cause some serious harm.
                uint256 payloadSize = uint256(uint16(bytes2(encodedPayload[pointer:pointer += 2])));
                bytes calldata payload = encodedPayload[pointer:pointer += payloadSize];

                // The payload is hashed immediately to reduce memory expansion costs.
                bytes32 hashedPayload = keccak256(payload);
                payloadHashes[index] = hashedPayload;
            }
        }
    }
}
