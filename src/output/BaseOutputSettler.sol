// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IOutputCallback } from "../interfaces/IOutputCallback.sol";
import { IPayloadCreator } from "../interfaces/IPayloadCreator.sol";

import { IDestinationSettler } from "../interfaces/IERC7683.sol";

import { AssemblyLib } from "../libs/AssemblyLib.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../libs/OutputVerificationLib.sol";

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { BaseInputOracle } from "../oracles/BaseInputOracle.sol";

import { FillerDataLib } from "../libs/FillerDataLib.sol";
import { FulfilmentLib } from "../libs/FulfilmentLib.sol";
import { OutputFillLib } from "../libs/OutputFillLib.sol";

/**
 * @notice Base Output Settler implementing logic for settling outputs.
 * Does not support native tokens
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
 * This contract supports 4 order types:
 * - Limit Order & Exclusive Limit Orders
 * - Dutch Auctions & Exclusive Dutch Auctions
 * Exclusive orders has a period in the beginning of the order where it can only be filled by a specific solver.
 * @dev Tokens never touch this contract but goes directly from solver to user.
 */
contract BaseOutputSettler is IDestinationSettler, IPayloadCreator, BaseInputOracle {
    using OutputFillLib for bytes;
    using FulfilmentLib for bytes;
    using FillerDataLib for bytes;

    /// @dev Fill deadline has passed
    error FillDeadline();
    /// @dev Attempting to fill an output that has already been filled by a different solver
    error AlreadyFilled();
    /// @dev Oracle attestation doesn't match stored fill record
    error InvalidAttestation(bytes32 storedFillRecordHash, bytes32 givenFillRecordHash);
    /// @dev Proposed solver is zero address
    error ZeroValue();
    /// @dev Payload is too small to be a valid fill description
    error PayloadTooSmall();
    /// @dev Order type not implemented
    error NotImplemented();
    /// @dev Exclusive order is attempted by a different solver
    error ExclusiveTo(bytes32 solver);

    /**
     * @notice Sets outputs as filled by their solver identifier, such that outputs won't be filled twice.
     */
    mapping(bytes32 orderId => mapping(bytes32 outputHash => bytes32 payloadHash)) internal _fillRecords;

    /**
     * @notice Emitted when an output is successfully filled.
     */
    event OutputFilled(bytes32 indexed orderId, bytes32 solver, uint32 timestamp, bytes output, uint256 finalAmount);

    /**
     * @dev Computes the fill record hash for a given solver and timestamp.
     * @param solver The address of the solver.
     * @param timestamp The timestamp when the fill occurred.
     * @return fillRecordHash The computed hash used to track fills.
     */
    function _getFillRecordHash(bytes32 solver, uint32 timestamp) internal pure returns (bytes32 fillRecordHash) {
        fillRecordHash = keccak256(abi.encodePacked(solver, timestamp));
    }

    /**
     * @dev Retrieves the fill record for a specific order output by hash.
     * @param orderId The unique identifier of the order.
     * @param outputHash The hash of the output to check.
     * @return payloadHash The fill record hash if the output has been filled, zero otherwise.
     */
    function getFillRecord(bytes32 orderId, bytes32 outputHash) public view returns (bytes32 payloadHash) {
        payloadHash = _fillRecords[orderId][outputHash];
    }

    /**
     * @dev Retrieves the fill record for a specific order output by MandateOutput struct.
     * @param orderId The unique identifier of the order.
     * @param output The MandateOutput struct to check.
     * @return payloadHash The fill record hash if the output has been filled, zero otherwise.
     */
    function getFillRecord(bytes32 orderId, MandateOutput calldata output) public view returns (bytes32 payloadHash) {
        payloadHash = _fillRecords[orderId][MandateOutputEncodingLib.getMandateOutputHash(output)];
    }
    /**
     * @dev Performs basic validation and fills output if unfilled.
     * If an order has already been filled given the output & fillDeadline, then this function does not "re"fill the
     * order but returns early.
     * @dev This function links the fill to the outcome of the external call. If the external call cannot execute,
     * the output is not fillable.
     * Does not automatically submit the order (send the proof).
     *                          !Do not make orders with repeated outputs!.
     * The implementation strategy (verify then fill) means that an order with repeat outputs
     * (say 1 Ether to Alice & 1 Ether to Alice) can be filled by sending 1 Ether to Alice ONCE.
     * @param orderId The unique identifier of the order.
     * @param output The serialized output data to fill.
     * @param proposedSolver The address of the solver filling the output.
     * @return fillRecordHash The hash of the fill record.
     */

    function _fill(
        bytes32 orderId,
        bytes calldata output,
        bytes32 proposedSolver
    ) internal virtual returns (bytes32 fillRecordHash) {
        bytes32 token = output.token();
        address recipient = address(uint160(uint256(output.recipient())));

        if (proposedSolver == bytes32(0)) revert ZeroValue();
        OutputVerificationLib._isThisChain(output.chainId());
        OutputVerificationLib._isThisOutputSettler(output.settler());

        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHashFromBytes(output.removeFillDeadline());
        bytes32 existingFillRecordHash = _fillRecords[orderId][outputHash];
        if (existingFillRecordHash != bytes32(0)) return existingFillRecordHash; // Early return if already solved.

        // The above and below lines act as a local re-entry check.
        uint32 fillTimestamp = uint32(block.timestamp);
        fillRecordHash = _getFillRecordHash(proposedSolver, fillTimestamp);
        _fillRecords[orderId][outputHash] = fillRecordHash;

        // Storage has been set. Fill the output.
        uint256 outputAmount = _resolveOutput(output, proposedSolver);
        SafeTransferLib.safeTransferFrom(address(uint160(uint256(token))), msg.sender, recipient, outputAmount);

        bytes calldata callbackData = output.callbackData();

        if (callbackData.length > 0) IOutputCallback(recipient).outputFilled(token, outputAmount, callbackData);

        emit OutputFilled(orderId, proposedSolver, fillTimestamp, output, outputAmount);

        return fillRecordHash;
    }

    /**
     * @dev Computes a dutch auction slope.
     * @dev The auction function is fixed until x=startTime at y=minimumAmount + slope · (stopTime - startTime) then it
     * linearly decreases until x=stopTime at y=minimumAmount which it remains at.
     *  If stopTime <= startTime return minimumAmount.
     * @param minimumAmount After stoptime, this will be the price. The returned amount is never less.
     * @param slope Every second the auction function is decreased by the slope.
     * @param startTime Timestamp when the returned amount begins decreasing. Returns a fixed maximum amount otherwise.
     * @param stopTime Timestamp when the slope stops counting and returns minimumAmount perpetually.
     * @return currentAmount Computed dutch auction amount.
     */
    function _dutchAuctionSlope(
        uint256 minimumAmount,
        uint256 slope,
        uint32 startTime,
        uint32 stopTime
    ) internal view returns (uint256 currentAmount) {
        uint32 currentTime = uint32(FixedPointMathLib.max(block.timestamp, uint256(startTime)));
        if (stopTime < currentTime) return minimumAmount; // This check also catches stopTime < startTime.

        uint256 timeDiff;
        unchecked {
            timeDiff = stopTime - currentTime; // unchecked: stopTime > currentTime
        }
        return minimumAmount + slope * timeDiff;
    }

    /**
     * @dev Executes order specific logic and returns the amount.
     * @param output The serialized output data to resolve.
     * @param solver The address of the solver attempting to fill the output.
     * @return amount The final amount to be transferred (may differ from base amount for Dutch auctions).
     * @dev This function implements order type-specific logic:
     * - Limit orders: Returns the base amount
     * - Dutch auctions: Calculates time-based price using slope
     * - Exclusive orders: Validates solver permissions and returns appropriate amount
     * - Reverts with NotImplemented() for unsupported order types
     */
    function _resolveOutput(bytes calldata output, bytes32 solver) internal view virtual returns (uint256 amount) {
        amount = output.amount();

        bytes calldata fulfilmentData = output.contextData();

        uint16 fulfillmentLength = uint16(fulfilmentData.length);

        if (fulfillmentLength == 0) return amount;

        bytes1 orderType = fulfilmentData.orderType();

        if (orderType == FulfilmentLib.LIMIT_ORDER) {
            if (fulfillmentLength != 1) revert FulfilmentLib.InvalidContextDataLength();
            return amount;
        }
        if (orderType == FulfilmentLib.DUTCH_AUCTION) {
            (uint32 startTime, uint32 stopTime, uint256 slope) = fulfilmentData.getDutchAuctionData();
            return _dutchAuctionSlope(amount, slope, startTime, stopTime);
        }

        if (orderType == FulfilmentLib.EXCLUSIVE_LIMIT_ORDER) {
            (bytes32 exclusiveFor, uint32 startTime) = fulfilmentData.getExclusiveLimitOrderData();
            if (startTime > block.timestamp && exclusiveFor != solver) revert ExclusiveTo(exclusiveFor);
            return amount;
        }
        if (orderType == FulfilmentLib.EXCLUSIVE_DUTCH_AUCTION) {
            (bytes32 exclusiveFor, uint32 startTime, uint32 stopTime, uint256 slope) =
                fulfilmentData.getExclusiveDutchAuctionData();
            if (startTime > block.timestamp && exclusiveFor != solver) revert ExclusiveTo(exclusiveFor);
            return _dutchAuctionSlope(amount, slope, startTime, stopTime);
        }
        revert NotImplemented();
    }

    // --- External Solver Interface --- //

    /**
     * @dev External fill interface for filling a single output (idempotent operation).
     * @dev This function is idempotent - it can be called multiple times safely. If the output is already filled,
     * it returns the existing fill record hash without reverting. This makes it suitable for retry mechanisms
     * and scenarios where multiple parties might attempt to fill the same output.
     * @param orderId The unique identifier of the order.
     * @param originData The serialized output data to fill.
     * @param fillerData The solver data containing the proposed solver.
     * @return fillRecordHash The hash of the fill record.
     */
    function fill(
        bytes32 orderId,
        bytes calldata originData,
        bytes calldata fillerData
    ) external virtual returns (bytes32) {
        uint48 fillDeadline = originData.fillDeadline();

        if (fillDeadline < block.timestamp) revert FillDeadline();

        bytes32 proposedSolver = fillerData.proposedSolver();

        return _fill(orderId, originData, proposedSolver);
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
     * @param orderId The unique identifier of the order.
     * @param outputs Array of serialized output data to fill.
     * @param fillerData The solver data containing the proposed solver.
     */
    function fillOrderOutputs(bytes32 orderId, bytes[] calldata outputs, bytes calldata fillerData) external virtual {
        bytes32 proposedSolver = fillerData.proposedSolver();

        uint48 fillDeadline = outputs[0].fillDeadline();

        if (fillDeadline < block.timestamp) revert FillDeadline();

        bytes32 fillRecordHash = _fill(orderId, outputs[0], proposedSolver);
        bytes32 expectedFillRecordHash = _getFillRecordHash(proposedSolver, uint32(block.timestamp));

        if (fillRecordHash != expectedFillRecordHash) revert AlreadyFilled();

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

    /**
     * @notice Sets an attestation for a fill description to enable cross-chain validation.
     * @param orderId The unique identifier of the order.
     * @param solver The address of the solver who filled the output.
     * @param timestamp The timestamp when the fill occurred.
     * @param output The MandateOutput struct that was filled.
     */
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
