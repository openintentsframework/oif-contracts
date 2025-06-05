// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct MandateOutput {
    /// @dev Oracle implementation responsible for collecting the proof from settler on output chain.
    bytes32 oracle;
    /// @dev Output Settler on the output chain responsible for settling the output payment.
    bytes32 settler;
    uint256 chainId;
    bytes32 token;
    uint256 amount;
    bytes32 recipient;
    /// @dev Data that will be delivered to recipient through the settlement callback on the output chain. Can be used
    /// to schedule additional actions.
    bytes call;
    /// @dev Additional output context for the output settlement, encoding order types or other information.
    bytes context;
}

/**
 * @notice Converts MandateOutputs to and from byte payloads.
 * @dev This library defines 2 payload encodings, one for internal usage and one for cross-chain communication.
 * - MandateOutput serialisation of the exact output on a output chain (encodes the entirety MandateOutput struct). This
 * encoding may be used to obtain a collision free hash to uniquely identify a MandateOutput.
 * - FillDescription serialisation to describe describe what has been filled on a remote chain. Its purpose is to
 * provide a source of truth of a remote action.
 * The encoding scheme uses 2 bytes long length identifiers. As a result, neither call nor context exceed 65'535 bytes.
 *
 * Serialised MandateOutput
 *      REMOTE_ORACLE           0               (32 bytes)
 *      + REMOTE_FILLER         32              (32 bytes)
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
        bytes calldata call = mandateOutput.call;
        bytes calldata context = mandateOutput.context;
        if (call.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();

        return encodedOutput = abi.encodePacked(
            mandateOutput.oracle,
            mandateOutput.settler,
            mandateOutput.chainId,
            mandateOutput.token,
            mandateOutput.amount,
            mandateOutput.recipient,
            uint16(call.length), // To protect against data collisions
            call,
            uint16(context.length), // To protect against data collisions
            context
        );
    }

    function encodeMandateOutputMemory(
        MandateOutput memory mandateOutput
    ) internal pure returns (bytes memory encodedOutput) {
        bytes memory call = mandateOutput.call;
        bytes memory context = mandateOutput.context;
        if (call.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();

        return encodedOutput = abi.encodePacked(
            mandateOutput.oracle,
            mandateOutput.settler,
            mandateOutput.chainId,
            mandateOutput.token,
            mandateOutput.amount,
            mandateOutput.recipient,
            uint16(call.length), // To protect against data collisions
            call,
            uint16(context.length), // To protect against data collisions
            context
        );
    }

    /**
     * @notice Hash of an MandateOutput intended for output identification.
     * @dev This identifier is purely intended for the remote chain. It should never be ferried cross-chain.
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
        bytes memory call,
        bytes memory context
    ) internal pure returns (bytes memory encodedOutput) {
        if (call.length > type(uint16).max) revert CallOutOfRange();
        if (context.length > type(uint16).max) revert ContextOutOfRange();

        return encodedOutput = abi.encodePacked(
            solver,
            orderId,
            timestamp,
            token,
            amount,
            recipient,
            uint16(call.length), // To protect against data collisions
            call,
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
            mandateOutput.call,
            mandateOutput.context
        );
    }

    function encodeFillDescriptionM(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        MandateOutput memory mandateOutput
    ) internal pure returns (bytes memory encodedOutput) {
        return encodedOutput = encodeFillDescription(
            solver,
            orderId,
            timestamp,
            mandateOutput.token,
            mandateOutput.amount,
            mandateOutput.recipient,
            mandateOutput.call,
            mandateOutput.context
        );
    }
}
