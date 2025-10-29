// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { Address } from "openzeppelin/utils/Address.sol";

import { IAttester } from "../interfaces/IAttester.sol";
import { IOutputCallback } from "../interfaces/IOutputCallback.sol";

import { AssemblyLib } from "../libs/AssemblyLib.sol";
import { LibAddress } from "../libs/LibAddress.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../libs/OutputVerificationLib.sol";

import { BaseInputOracle } from "../oracles/BaseInputOracle.sol";

/**
 * @notice Base Output Settler implementing logic for settling outputs.
 * Supports both native tokens (ETH) and ERC20 tokens
 * This base output settler implements logic to work as both a Attester (for oracles) and as an oracle itself.
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
 * **IMPORTANT SECURITY NOTE - FIRST SOLVER ORDER OWNERSHIP:**
 * By default, the owner (address able to claim funds after and order is settled) is the solver of the first output, in
 * case of an order with multiple outputs.
 * This leads to some security considerations:
 * For Users:
 * 1. Denial of Service Risk: The solver of the first output may refuse to fill the other outputs, delaying the order
 * execution until expiry (when user can be refunded).
 *    - Mitigation: Users should ensure that the first output is the most important/valuable, making this attack more
 * costly.
 * 2. Exploitation of different order types: When opening orders, users are able to set different rules for filling
 * them, i.e., output amounts could be determined by a dutch auction. If the order has multiple outputs, the solver of
 * the first output (the owner) can delay the filling of other outputs, which could lead to worse prices for users.
 *    - Mitigation: Users should be cautious when opening orders whose outputs have variable output amounts. In general,
 * users SHOULD NOT open orders where any output other than the first has an order type whose output amount is
 * determined by a time based mechanism. Note that other mechanisms can also be used to manipulate prices.
 *
 * Users should also consider opening orders with exclusivity for trusted solvers, especially when the order has
 * multiple outputs.
 *
 * For Solvers:
 * 1. Multiple outputs risk: When filling an order, the solver MUST be aware that they will only be able to finalise the
 * order (i.e., claim funds) after filling all of the outputs (potentially in multiple chains).
 * If the solver is unable to do so, the user will be refunded and the order will be considered as not filled.
 *    - Mitigation: Solvers should be aware of all of the risks and variables, such as:
 *      - all outputs must be filled before `fillDeadline` and the proof of the filling transaction must be handled by
 * each oracle before `expiry` time.
 *      - Solvers should be aware that some outputs have callbacks, which is an arbitrary code that is executed during
 * the filling of the output. They should refuse orders with callbacks outside of the primary batch (that containing the
 * first output) unless it's known that it can't possibly revert (considering that a successful off-chain simulation is
 * not a guarantee of on-chain success)
 *        They should understand the risks of each callback and the potential for them to revert the filling of the
 * output, which could lead to the solver not being able to finalise the order.
 */
abstract contract OutputSettlerBase is IAttester, BaseInputOracle {
    using LibAddress for bytes32;
    using LibAddress for uint256;

    /// @dev Fill deadline has passed
    error FillDeadline();
    /// @dev Attempting to fill an output that has already been filled by a different solver
    error AlreadyFilled();
    /// @dev Oracle attestation doesn't match stored fill record
    error InvalidAttestation(bytes32 storedFillRecordHash, bytes32 givenFillRecordHash);
    /// @dev Payload is too small to be a valid fill description
    error PayloadTooSmall();

    /**
     * @notice Sets outputs as filled by their solver identifier, such that outputs won't be filled twice.
     */
    mapping(bytes32 orderId => mapping(bytes32 outputHash => bytes32 payloadHash)) internal _fillRecords;

    /**
     * @notice Emitted when an output is successfully filled.
     */
    event OutputFilled(
        bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output, uint256 finalAmount
    );

    /**
     * @dev Computes the fill record hash for a given solver and timestamp.
     * @param solver The address of the solver.
     * @param timestamp The timestamp when the fill occurred.
     * @return fillRecordHash The computed hash used to track fills.
     */
    function _getFillRecordHash(
        bytes32 solver,
        uint32 timestamp
    ) internal pure returns (bytes32 fillRecordHash) {
        fillRecordHash = keccak256(abi.encodePacked(solver, timestamp));
    }

    /**
     * @dev Retrieves the fill record for a specific order output by hash.
     * @param orderId The unique identifier of the order.
     * @param outputHash The hash of the output to check.
     * @return payloadHash The fill record hash if the output has been filled, zero otherwise.
     */
    function getFillRecord(
        bytes32 orderId,
        bytes32 outputHash
    ) public view returns (bytes32 payloadHash) {
        payloadHash = _fillRecords[orderId][outputHash];
    }

    /**
     * @dev Retrieves the fill record for a specific order output by MandateOutput struct.
     * @param orderId The unique identifier of the order.
     * @param output The MandateOutput struct to check.
     * @return payloadHash The fill record hash if the output has been filled, zero otherwise.
     */
    function getFillRecord(
        bytes32 orderId,
        MandateOutput calldata output
    ) public view returns (bytes32 payloadHash) {
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
     * @param output The `MandateOutput` struct to fill.
     * @param fillerData The solver data.
     * @return fillRecordHash The hash of the fill record.
     */
    function _fill(
        bytes32 orderId,
        MandateOutput calldata output,
        bytes calldata fillerData
    ) internal virtual returns (bytes32 fillRecordHash, bytes32 solver) {
        OutputVerificationLib._isThisChain(output.chainId);
        OutputVerificationLib._isThisOutputSettler(output.settler);

        uint32 fillTimestamp = uint32(block.timestamp);
        uint256 outputAmount;
        (solver, outputAmount) = _resolveOutput(output, fillerData);
        {
            bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHash(output);
            bytes32 existingFillRecordHash = _fillRecords[orderId][outputHash];

            // Early return if already filled.
            if (existingFillRecordHash != bytes32(0)) return (existingFillRecordHash, solver);

            // The above and below lines act as a local re-entry check.
            fillRecordHash = _getFillRecordHash(solver, fillTimestamp);
            _fillRecords[orderId][outputHash] = fillRecordHash;
        }
        // Storage has been set. Fill the output.
        bytes32 tokenIdentifier = output.token;
        address recipient = output.recipient.fromIdentifier();

        if (tokenIdentifier == bytes32(0)) {
            Address.sendValue(payable(recipient), outputAmount);
        } else {
            SafeERC20.safeTransferFrom(
                IERC20(uint256(tokenIdentifier).validatedCleanAddress()), msg.sender, recipient, outputAmount
            );
        }

        bytes calldata callbackData = output.callbackData;
        if (callbackData.length > 0) {
            IOutputCallback(recipient).outputFilled(tokenIdentifier, outputAmount, callbackData);
        }
        emit OutputFilled(orderId, solver, fillTimestamp, output, outputAmount);

        return (fillRecordHash, solver);
    }

    /**
     * @dev Executes order specific logic and returns the amount.
     * @param output to resolve.
     * @param fillerData The solver data.
     * @return solver The address of the solver filling the output.
     * @return amount The final amount to be transferred (may differ from base amount for Dutch auctions).
     */
    function _resolveOutput(
        MandateOutput calldata output,
        bytes calldata fillerData
    ) internal view virtual returns (bytes32 solver, uint256 amount);

    // --- External Solver Interface --- //

    /**
     * @dev External fill interface for filling a single output (idempotent operation).
     * @dev This function is idempotent - it can be called multiple times safely. If the output is already filled,
     * it returns the existing fill record hash without reverting. This makes it suitable for retry mechanisms
     * and scenarios where multiple parties might attempt to fill the same output.
     * @param orderId The unique identifier of the order.
     * @param output The `MandateOutput` struct to fill.
     * @param fillerData The solver data containing the proposed solver.
     * @return fillRecordHash The hash of the fill record.
     */
    function fill(
        bytes32 orderId,
        MandateOutput calldata output,
        uint48 fillDeadline,
        bytes calldata fillerData
    ) external payable virtual returns (bytes32 fillRecordHash) {
        if (fillDeadline < block.timestamp) revert FillDeadline();
        (fillRecordHash,) = _fill(orderId, output, fillerData);

        refundNativeExcess();
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
     * @param outputs Array of `MandateOutput` structs to fill
     * @param fillerData The solver data containing the proposed solver.
     */
    function fillOrderOutputs(
        bytes32 orderId,
        MandateOutput[] calldata outputs,
        uint48 fillDeadline,
        bytes calldata fillerData
    ) external payable virtual {
        if (fillDeadline < block.timestamp) revert FillDeadline();

        (bytes32 fillRecordHash, bytes32 solver) = _fill(orderId, outputs[0], fillerData);

        bytes32 expectedFillRecordHash = _getFillRecordHash(solver, uint32(block.timestamp));
        if (fillRecordHash != expectedFillRecordHash) revert AlreadyFilled();

        uint256 numOutputs = outputs.length;
        for (uint256 i = 1; i < numOutputs; ++i) {
            _fill(orderId, outputs[i], fillerData);
        }

        refundNativeExcess();
    }

    /**
     * @notice Refunds the native token excess value sent to the contract.
     */
    function refundNativeExcess() internal {
        uint256 excess = address(this).balance;
        if (excess > 0) Address.sendValue(payable(msg.sender), excess);
    }

    // --- IAttester --- //

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
    function hasAttested(
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
        bytes32 attester = output.settler;
        OutputVerificationLib._isThisOutputSettler(attester);
        bytes32 oracle = output.oracle;
        OutputVerificationLib._isThisOutputOracle(oracle);
        uint256 chainId = output.chainId;
        OutputVerificationLib._isThisChain(chainId);
        _attestations[chainId][attester][oracle][dataHash] = true;
    }
}
