// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IOutputCallback } from "../interfaces/IOutputCallback.sol";
import { IPayloadCreator } from "../interfaces/IPayloadCreator.sol";

import { AssemblyLib } from "../libs/AssemblyLib.sol";
import { LibAddress } from "../libs/LibAddress.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../libs/OutputVerificationLib.sol";

import { BaseInputOracle } from "../oracles/BaseInputOracle.sol";

/**
 * @notice Base Output Settler implementing logic for settling outputs.
 * Does not support native coins.
 * This base output settler implements logic to work as both a PayloadCreator (for oracles) and as an oracle itself.
 *
 * @dev **Fill Function Patterns:**
 * This contract provides two distinct fill patterns with different semantics:
 *
 * 1. **Single Fill (`fill`)** - Idempotent Operation:
 *    - Safe to call multiple times
 *    - Returns existing fill record if already filled
 *    - Suitable for retry mechanisms and concurrent filling attempts
 *    - Use when you want graceful handling of already-filled outputs
 *
 * 2. **Batch Fill (`fillOrderOutputs`)** - Atomic Competition Operation:
 *    - Implements solver competition semantics
 *    - Reverts if first output already filled by different solver
 *    - Ensures atomic all-or-nothing batch filling
 *    - Use when you need to atomically claim an entire multi-output order
 *
 * Choose the appropriate pattern based on your use case requirements.
 */
abstract contract BaseOutputSettler is IPayloadCreator, BaseInputOracle {
    using LibAddress for address;

    error FillDeadline();
    error AlreadyFilled();
    error InvalidAttestation(bytes32 storedFillRecordHash, bytes32 givenFillRecordHash);
    error ZeroValue();
    error PayloadTooSmall();

    /**
     * @dev Validates that the fill deadline has not passed.
     * @param fillDeadline The deadline timestamp to check against.
     */
    modifier checkFillDeadline(
        uint32 fillDeadline
    ) {
        if (fillDeadline < block.timestamp) revert FillDeadline();
        _;
    }

    /**
     * @notice Sets outputs as filled by their solver identifier, such that outputs won't be filled twice.
     */
    mapping(bytes32 orderId => mapping(bytes32 outputHash => bytes32 payloadHash)) internal _fillRecords;

    /**
     * @notice Output has been filled.
     */
    event OutputFilled(
        bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output, uint256 finalAmount
    );

    function _getFillRecordHash(bytes32 solver, uint32 timestamp) internal pure returns (bytes32 fillRecordHash) {
        fillRecordHash = keccak256(abi.encodePacked(solver, timestamp));
    }

    function getFillRecord(bytes32 orderId, bytes32 outputHash) public view returns (bytes32 payloadHash) {
        payloadHash = _fillRecords[orderId][outputHash];
    }

    function getFillRecord(bytes32 orderId, MandateOutput calldata output) public view returns (bytes32 payloadHash) {
        payloadHash = _fillRecords[orderId][MandateOutputEncodingLib.getMandateOutputHash(output)];
    }

    /**
     * @dev Virtual function for extensions to implement output resolution logic.
     * @param output The given output to resolve.
     * @param proposedSolver The proposed solver to check exclusivity against.
     * @return amount The computed amount for the output.
     */
    function _resolveOutput(
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) internal view virtual returns (uint256 amount) {
        // Default implementation returns the output amount
        return output.amount;
    }

    /**
     * @notice Performs basic validation and fills output if unfilled.
     * If an order has already been filled given the output & fillDeadline, then this function does not "re"fill the
     * order but returns early.
     * @dev This fill function links the fill to the outcome of the external call. If the external call cannot execute,
     * the output is not fillable.
     * Does not automatically submit the order (send the proof).
     *                          !Do not make orders with repeated outputs!.
     * The implementation strategy (verify then fill) means that an order with repeat outputs
     * (say 1 Ether to Alice & 1 Ether to Alice) can be filled by sending 1 Ether to Alice ONCE.
     * @param orderId Input chain order identifier. Is used as is, not checked for validity.
     * @param output The given output to fill. Is expected to belong to a greater order identified by orderId
     * @param proposedSolver Solver identifier to be sent to input chain.
     * @return fillRecordHash Hash of the fill record. Returns existing hash if already filled, new hash if successfully
     * filled.
     */
    function _fill(
        bytes32 orderId,
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) internal returns (bytes32 fillRecordHash) {
        if (proposedSolver == bytes32(0)) revert ZeroValue();
        OutputVerificationLib._isThisChain(output.chainId);
        OutputVerificationLib._isThisOutputSettler(output.settler);

        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHash(output);
        bytes32 existingFillRecordHash = _fillRecords[orderId][outputHash];
        // Return existing record hash if already solved.
        if (existingFillRecordHash != bytes32(0)) return existingFillRecordHash;
        // The above and below lines act as a local re-entry check.
        uint32 fillTimestamp = uint32(block.timestamp);
        fillRecordHash = _getFillRecordHash(proposedSolver, fillTimestamp);
        _fillRecords[orderId][outputHash] = fillRecordHash;

        // Storage has been set. Fill the output.
        uint256 outputAmount = _resolveOutput(output, proposedSolver);
        address recipient = address(uint160(uint256(output.recipient)));
        SafeTransferLib.safeTransferFrom(address(uint160(uint256(output.token))), msg.sender, recipient, outputAmount);
        if (output.call.length > 0) IOutputCallback(recipient).outputFilled(output.token, outputAmount, output.call);

        emit OutputFilled(orderId, proposedSolver, fillTimestamp, output, outputAmount);
        return fillRecordHash;
    }

    // --- External Solver Interface --- //

    /**
     * @notice External fill interface for filling a single output (idempotent operation).
     * @dev This function is idempotent - it can be called multiple times safely. If the output is already filled,
     * it returns the existing fill record hash without reverting. This makes it suitable for retry mechanisms
     * and scenarios where multiple parties might attempt to fill the same output.
     *
     * @param fillDeadline If the transaction is executed after this timestamp, the call will fail.
     * @param orderId Input chain order identifier. Is used as is, not checked for validity.
     * @param output Given output to fill. Is expected to belong to a greater order identified by orderId.
     * @param proposedSolver Solver identifier to be sent to input chain.
     * @return bytes32 Fill record hash. Returns existing hash if already filled, new hash if successfully filled.
     */
    function fill(
        uint32 fillDeadline,
        bytes32 orderId,
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) external virtual checkFillDeadline(fillDeadline) returns (bytes32) {
        return _fill(orderId, output, proposedSolver);
    }

    // -- Batch Solving -- //

    /**
     * @notice Atomic batch fill interface for filling multiple outputs (non-idempotent operation).
     * @dev This function implements atomic batch filling with solver competition semantics. Unlike the single
     * `fill()` function, this is NOT idempotent - it will revert if the first output has already been filled
     * by another solver. This ensures that only one solver can "win" the entire order.
     *
     * **Behavioral differences from single fill():**
     * - REVERTS with `AlreadyFilled()` if the first output is already filled (solver competition)
     * - Subsequent outputs can be already filled (they are skipped)
     * - All fills in the batch succeed or the entire transaction reverts (atomicity)
     *
     * **Solver Selection Logic:**
     * The first output determines which solver "wins" the entire order. This prevents solver conflicts
     * and ensures consistent solver attribution across all outputs in a multi-output order.
     *
     * @param fillDeadline If the transaction is executed after this timestamp, the call will fail.
     * @param orderId Input chain order identifier. Is used as is, not checked for validity.
     * @param outputs Given outputs to fill. Ensure that the **first** order output is the first output for this call.
     * @param proposedSolver Solver to be sent to origin chain. If the first output has a different solver, reverts.
     */
    function fillOrderOutputs(
        uint32 fillDeadline,
        bytes32 orderId,
        MandateOutput[] calldata outputs,
        bytes32 proposedSolver
    ) external checkFillDeadline(fillDeadline) {
        // Atomic check: first output must not be already filled (solver competition)
        bytes32 fillRecordHash = _fill(orderId, outputs[0], proposedSolver);
        bytes32 expectedFillRecordHash = _getFillRecordHash(proposedSolver, uint32(block.timestamp));
        if (fillRecordHash != expectedFillRecordHash) revert AlreadyFilled();

        // Fill remaining outputs (can skip if already filled)
        uint256 numOutputs = outputs.length;
        for (uint256 i = 1; i < numOutputs; ++i) {
            _fill(orderId, outputs[i], proposedSolver);
        }
    }

    // --- External Calls --- //

    /**
     * @notice Allows estimating the gas used for an external call.
     * @dev To call, set msg.sender to address(0). This call can never be executed on-chain. It should also be noted
     * that application can cheat and implement special logic for tx.origin == 0.
     * @param trueAmount Amount computed for the order.
     * @param output Order output to simulate the call for.
     */
    function call(uint256 trueAmount, MandateOutput calldata output) external {
        // Disallow calling on-chain.
        require(msg.sender == address(0));

        IOutputCallback(address(uint160(uint256(output.recipient)))).outputFilled(output.token, trueAmount, output.call);
    }

    // --- IPayloadCreator --- //

    /**
     * @notice Helper function to check whether a payload is valid.
     * @dev Works by checking if the entirety of the payload has been recorded as valid. Every byte of the payload is
     * checked to ensure the payload has been filled.
     * @param payload keccak256 hash of the relevant payload.
     * @return bool Whether or not the payload has been recorded as filled.
     */
    function _isPayloadValid(
        bytes calldata payload
    ) internal view virtual returns (bool) {
        // Check if the payload is large enough for it to be a fill description.
        if (payload.length < 168) revert PayloadTooSmall();
        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHashFromCommonPayload(
            bytes32(uint256(uint160(msg.sender))), // Oracle
            bytes32(uint256(uint160(address(this)))), // Settler
            block.chainid,
            payload[68:]
        );
        bytes32 payloadOrderId = MandateOutputEncodingLib.loadOrderIdFromFillDescription(payload);
        bytes32 fillRecord = _fillRecords[payloadOrderId][outputHash];

        // Get the expected record based on the fillDescription (payload).
        bytes32 payloadSolver = MandateOutputEncodingLib.loadSolverFromFillDescription(payload);
        uint32 payloadTimestamp = MandateOutputEncodingLib.loadTimestampFromFillDescription(payload);
        bytes32 expectedFillRecord = _getFillRecordHash(payloadSolver, payloadTimestamp);

        return fillRecord == expectedFillRecord;
    }

    /**
     * @notice Returns whether a set of payloads have been approved by this contract.
     */
    function arePayloadsValid(
        bytes[] calldata payloads
    ) external view returns (bool accumulator) {
        uint256 numPayloads = payloads.length;
        accumulator = true;
        for (uint256 i; i < numPayloads; ++i) {
            accumulator = AssemblyLib.and(accumulator, _isPayloadValid(payloads[i]));
        }
    }

    // --- Oracle Interfaces --- //

    function setAttestation(
        bytes32 orderId,
        bytes32 solver,
        uint32 timestamp,
        MandateOutput calldata output
    ) external {
        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHash(output);
        bytes32 existingFillRecordHash = _fillRecords[orderId][outputHash];
        bytes32 givenFillRecordHash = _getFillRecordHash(solver, timestamp);
        if (existingFillRecordHash != givenFillRecordHash) {
            revert InvalidAttestation(existingFillRecordHash, givenFillRecordHash);
        }

        bytes32 dataHash = keccak256(MandateOutputEncodingLib.encodeFillDescription(solver, orderId, timestamp, output));

        // Check that we set the mapping correctly.
        bytes32 application = output.settler;
        OutputVerificationLib._isThisOutputSettler(application);
        bytes32 oracle = output.oracle;
        OutputVerificationLib._isThisOutputOracle(oracle);
        uint256 chainId = output.chainId;
        OutputVerificationLib._isThisChain(chainId);
        _attestations[chainId][application][oracle][dataHash] = true;
    }
}
