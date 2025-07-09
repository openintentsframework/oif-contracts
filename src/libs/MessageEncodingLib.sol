// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Library to aid in encoding a series of payloads and decoding a series of payloads.
 * @dev This library does not understand the payloads. Likewise, when parsed payloads are returned hashed.
 * This library uses uint16 lengths, as a result the maximum number of payloads in a single message is 65'535 and the
 * maximum number of bytes in a payload is 65'535.
 *
 * --- Data Structure ---
 *
 *  Common Structure (Repeated 0 times)
 *      SENDER_IDENTIFIER       0       (32 bytes)
 *      + NUM_PAYLOADS          32      (2 bytes)
 *
 *  Payloads (repeated NUM_PAYLOADS times)
 *      PAYLOAD_LENGTH          M_i+0   (2 bytes)
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
     * @param application Source of the messages.
     * @param payloads to be encoded. Maximum 65'535.
     * @return encodedPayload All payloads encoded into a single bytearray.
     */
    function encodeMessage(
        bytes32 application,
        bytes[] calldata payloads
    ) internal pure returns (bytes memory encodedPayload) {
        uint256 numPayloads = payloads.length;
        if (numPayloads > type(uint16).max) revert TooManyPayloads(numPayloads);
        encodedPayload = bytes.concat(application, bytes2(uint16(numPayloads)));
        for (uint256 i; i < numPayloads; ++i) {
            bytes calldata payload = payloads[i];
            uint256 payloadLength = payload.length;
            if (payloadLength > type(uint16).max) revert TooLargePayload(payloadLength);
            encodedPayload = abi.encodePacked(encodedPayload, uint16(payloadLength), payload);
        }
    }

    /**
     * @notice Decodes a bytearray consisting of encoded payloads.
     * @dev Hashes payloads to reduce memory expansion costs.
     * @return application Source of the messages on the payload.
     * @return payloadHashes A hash of every payload.
     */
    function getHashesOfEncodedPayloads(
        bytes calldata encodedPayload
    ) internal pure returns (bytes32 application, bytes32[] memory payloadHashes) {
        unchecked {
            assembly ("memory-safe") {
                application := calldataload(encodedPayload.offset) // = bytes32(encodedPayload[0:32]);
            }
            uint256 numPayloads = uint256(uint16(bytes2(encodedPayload[32:34])));

            payloadHashes = new bytes32[](numPayloads);
            uint256 pointer = 34;
            for (uint256 index = 0; index < numPayloads; ++index) {
                uint256 payloadSize = uint256(uint16(bytes2(encodedPayload[pointer:pointer += 2]))); // unchecked:
                    // calldata less than 2**256 bytes.
                bytes calldata payload = encodedPayload[pointer:pointer += payloadSize];
                bytes32 hashedPayload = keccak256(payload);
                payloadHashes[index] = hashedPayload;
            }
        }
    }
}
