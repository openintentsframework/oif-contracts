// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IOIFCallback } from "../interfaces/IOIFCallback.sol";
import { IPayloadCreator } from "../interfaces/IPayloadCreator.sol";

import { IDestinationSettler } from "../interfaces/IERC7683.sol";

import { AssemblyLib } from "../libs/AssemblyLib.sol";
import { LibAddress } from "../libs/LibAddress.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../libs/OutputVerificationLib.sol";

import { BaseOracle } from "../oracles/BaseOracle.sol";

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
abstract contract BaseOutputSettler is IDestinationSettler, IPayloadCreator, BaseOracle {
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
    // event OutputFilled(
    //     bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output, uint256 finalAmount
    // );

    event OutputFilled(bytes32 indexed orderId, bytes32 solver, uint32 timestamp, bytes output, uint256 finalAmount);

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

    function _fill(bytes32 orderId, bytes calldata output, bytes32 proposedSolver) internal virtual returns (bytes32);

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
    ) internal virtual returns (bytes32 fillRecordHash) {
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
        if (output.call.length > 0) IOIFCallback(recipient).outputFilled(output.token, outputAmount, output.call);

        //emit OutputFilled(orderId, proposedSolver, fillTimestamp, output, outputAmount);
        return fillRecordHash;
    }

    // --- External Solver Interface --- //

    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external returns (bytes32) {
        // TODO: handle fill deadline
        bytes32 proposedSolver;
        uint48 fillDeadline = uint48(bytes6(originData[0x00:0x06]));
        assembly ("memory-safe") {
            proposedSolver := calldataload(fillerData.offset)
        }

        if (fillDeadline < block.timestamp) revert FillDeadline();

        return _fill(orderId, originData, proposedSolver);
    }

    function _fill(
        bytes32 orderId,
        bytes calldata output,
        uint256 outputAmount,
        bytes32 proposedSolver
    ) internal virtual returns (bytes32 fillRecordHash) {
        bytes32 oracle;
        bytes32 settler;
        uint256 chainId;
        bytes32 token;
        uint256 amount;
        bytes32 recipientBytes;

        assembly ("memory-safe") {
            oracle := calldataload(add(output.offset, 0x06))
            settler := calldataload(add(output.offset, 0x26))
            chainId := calldataload(add(output.offset, 0x46))
            token := calldataload(add(output.offset, 0x66))
            amount := calldataload(add(output.offset, 0x86))
            recipientBytes := calldataload(add(output.offset, 0xa6))
        }

        if (proposedSolver == bytes32(0)) revert ZeroValue();
        OutputVerificationLib._isThisChain(chainId);
        OutputVerificationLib._isThisOutputSettler(settler);

        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHashFromBytes(output[6:]);
        bytes32 existingFillRecordHash = _fillRecords[orderId][outputHash];
        if (existingFillRecordHash != bytes32(0)) return existingFillRecordHash; // Early return if already solved.

        // The above and below lines act as a local re-entry check.
        uint32 fillTimestamp = uint32(block.timestamp);
        fillRecordHash = _getFillRecordHash(proposedSolver, fillTimestamp);
        _fillRecords[orderId][outputHash] = fillRecordHash;

        // Storage has been set. Fill the output.
        address recipient = address(uint160(uint256(recipientBytes)));
        SafeTransferLib.safeTransferFrom(address(uint160(uint256(token))), msg.sender, recipient, outputAmount);

        uint16 callDataLength = uint16(bytes2(output[0xc6:0xc8]));

        if (callDataLength > 0) {
            bytes calldata callData = output[0xc8:0xc8 + callDataLength];
            IOIFCallback(recipient).outputFilled(token, outputAmount, callData);
        }

        emit OutputFilled(orderId, proposedSolver, fillTimestamp, output, outputAmount);

        return fillRecordHash;
    }

    // -- Batch Solving -- //

    function fillOrderOutputs(bytes32 orderId, bytes[] calldata outputs, bytes calldata fillerData) external {
        bytes32 proposedSolver;
        assembly ("memory-safe") {
            proposedSolver := calldataload(fillerData.offset)
        }

        uint48 fillDeadline = uint48(bytes6(outputs[0][0x00:0x06]));

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

        IOIFCallback(address(uint160(uint256(output.recipient)))).outputFilled(output.token, trueAmount, output.call);
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
