// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput } from "../input/types/MandateOutputType.sol";

/**
 * @notice Converts MandateOutputs to and from byte payloads.
 * @dev This library defines 2 payload encodings, one for internal usage and one for cross-chain communication.
 * - MandateOutput serialisation of the exact output on a output chain (encodes the entirety MandateOutput struct). This
 * encoding may be used to obtain a collision free hash to uniquely identify a MandateOutput.
 * - FillDescription serialisation to describe describe what has been filled on a output chain. Its purpose is to
 * provide a source of truth of a output action.
 * The encoding scheme uses 2 bytes long length identifiers. As a result, neither callbackData nor context exceed 65'535
 * bytes.
 *
 * Serialised MandateOutput
 *      OUTPUT_ORACLE           0               (32 bytes)
 *      + OUTPUT_SETTLER        32              (32 bytes)
 *      + CHAIN_ID              64              (32 bytes)
 *      + COMMON_PAYLOAD        96
 *
 * Serialised FillDescription
 *      SOLVER                  0               (32 bytes)
 *      + ORDERID               32              (32 bytes)
 *      + TIMESTAMP             64              (4 bytes)
 *      + COMMON_PAYLOAD        68
 *
 * Common Payload. Is identical between both schemes
 *      + TOKEN                 Y               (32 bytes)
 *      + AMOUNT                Y+32            (32 bytes)
 *      + RECIPIENT             Y+64            (32 bytes)
 *      + CALL_LENGTH           Y+96            (2 bytes)
 *      + CALL                  Y+98            (LENGTH bytes)
 *      + CONTEXT_LENGTH        Y+98+RC_LENGTH  (2 bytes)
 *      + CONTEXT               Y+100+RC_LENGTH (LENGTH bytes)
 *
 * where Y is the offset from the specific encoding (either 68 or 96)
 */
library MandateOutputEncodingLib {
    error ContextOutOfRange();
    error CallOutOfRange();

    // --- MandateOutput --- //

    /**
     * @notice Predictable encoding of MandateOutput that deliberately overlaps with the payload encoding.
     * @dev The encoding scheme uses 2 bytes long length identifiers. As a result, neither call nor context exceed
     * 65'535 bytes.
     */
    function encodeMandateOutput(
        MandateOutput calldata mandateOutput
    ) internal pure returns (bytes memory encodedOutput) {
        bytes calldata callbackData = mandateOutput.callbackData;
        bytes calldata context = mandateOutput.context;
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();

        return encodedOutput = abi.encodePacked(
            mandateOutput.oracle,
            mandateOutput.settler,
            mandateOutput.chainId,
            mandateOutput.token,
            mandateOutput.amount,
            mandateOutput.recipient,
            uint16(callbackData.length), // To protect against data collisions
            callbackData,
            uint16(context.length), // To protect against data collisions
            context
        );
    }

    function encodeMandateOutputMemory(
        MandateOutput memory mandateOutput
    ) internal pure returns (bytes memory encodedOutput) {
        bytes memory callbackData = mandateOutput.callbackData;
        bytes memory context = mandateOutput.context;
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();

        return encodedOutput = abi.encodePacked(
            mandateOutput.oracle,
            mandateOutput.settler,
            mandateOutput.chainId,
            mandateOutput.token,
            mandateOutput.amount,
            mandateOutput.recipient,
            uint16(callbackData.length), // To protect against data collisions
            callbackData,
            uint16(context.length), // To protect against data collisions
            context
        );
    }

    /**
     * @notice Hash of an MandateOutput intended for output identification.
     * @dev This identifier is purely intended for the output chain. It should never be ferried cross-chain.
     * Chains or VMs may hash data differently.
     */
    function getMandateOutputHash(
        MandateOutput calldata output
    ) internal pure returns (bytes32) {
        return keccak256(encodeMandateOutput(output));
    }

    function getMandateOutputHashMemory(
        MandateOutput memory output
    ) internal pure returns (bytes32) {
        return keccak256(encodeMandateOutputMemory(output));
    }

    /**
     * @notice Hash of an MandateOutput computed based on a common payload.
     * @param oracle Address of the oracle of the output.
     * @param settler Address of the settler contract of the output.
     * @param chainId Identifier of the chain for the output.
     * @param commonPayload Common payload of the serialised outputs.
     * @return bytes32 OutputDescription hash.
     */
    function getMandateOutputHashFromCommonPayload(
        bytes32 oracle,
        bytes32 settler,
        uint256 chainId,
        bytes calldata commonPayload
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, settler, chainId, commonPayload));
    }

    // --- FillDescription Encoding --- //

    /**
     * @notice FillDescription encoding.
     * @dev The encoding scheme uses 2 bytes long length identifiers. As a result, neither call nor context exceed
     * 65'535 bytes.
     */
    function encodeFillDescription(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        bytes32 token,
        uint256 amount,
        bytes32 recipient,
        bytes calldata callbackData,
        bytes calldata context
    ) internal pure returns (bytes memory encodedOutput) {
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();

        return encodedOutput = abi.encodePacked(
            solver,
            orderId,
            timestamp,
            token,
            amount,
            recipient,
            uint16(callbackData.length), // To protect against data collisions
            callbackData,
            uint16(context.length), // To protect against data collisions
            context
        );
    }

    /**
     * @notice Memory version of encodeFillDescription
     */
    function encodeFillDescriptionMemory(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        bytes32 token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callbackData,
        bytes memory context
    ) internal pure returns (bytes memory encodedOutput) {
        if (callbackData.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();

        return encodedOutput = abi.encodePacked(
            solver,
            orderId,
            timestamp,
            token,
            amount,
            recipient,
            uint16(callbackData.length), // To protect against data collisions
            callbackData,
            uint16(context.length), // To protect against data collisions
            context
        );
    }

    /**
     * @notice Encodes an output description into a fill description.
     */
    function encodeFillDescription(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        MandateOutput calldata mandateOutput
    ) internal pure returns (bytes memory encodedOutput) {
        return encodedOutput = encodeFillDescription(
            solver,
            orderId,
            timestamp,
            mandateOutput.token,
            mandateOutput.amount,
            mandateOutput.recipient,
            mandateOutput.callbackData,
            mandateOutput.context
        );
    }

    function encodeFillDescriptionMemory(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        MandateOutput memory mandateOutput
    ) internal pure returns (bytes memory encodedOutput) {
        return encodedOutput = encodeFillDescriptionMemory(
            solver,
            orderId,
            timestamp,
            mandateOutput.token,
            mandateOutput.amount,
            mandateOutput.recipient,
            mandateOutput.callbackData,
            mandateOutput.context
        );
    }

    // --- FillDescription Decoding --- //

    /**
     * @notice Loads the solver of the output from a serialised fill description.
     * @param fillDescription Serialised fill description.
     * @return solver Solver of the output.
     */
    function loadSolverFromFillDescription(
        bytes calldata fillDescription
    ) internal pure returns (bytes32 solver) {
        assembly ("memory-safe") {
            solver := calldataload(fillDescription.offset)
        }
    }

    /**
     * @notice Loads the orderId from a serialised fill description.
     * @param fillDescription Serialised fill description.
     * @return orderId associated with the output.
     */
    function loadOrderIdFromFillDescription(
        bytes calldata fillDescription
    ) internal pure returns (bytes32 orderId) {
        assembly ("memory-safe") {
            orderId := calldataload(add(fillDescription.offset, 0x20))
        }
    }

    /**
     * @notice Loads the timestamp when the fill was made from a serialised fill description.
     * @param fillDescription Serialised fill description.
     * @return ts Timestamp associated with the output.
     */
    function loadTimestampFromFillDescription(
        bytes calldata fillDescription
    ) internal pure returns (uint32 ts) {
        assembly ("memory-safe") {
            // Clean the leftmost bytes: (32-4)*8 = 224
            ts := shr(224, shl(224, calldataload(add(fillDescription.offset, 0x24))))
        }
    }
}
