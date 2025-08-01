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

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { BaseOracle } from "../oracles/BaseOracle.sol";

import { OutputFillLib } from "../libs/OutputFillLib.sol";

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
    using OutputFillLib for bytes;

    error FillDeadline();
    error AlreadyFilled();
    error InvalidAttestation(bytes32 storedFillRecordHash, bytes32 givenFillRecordHash);
    error ZeroValue();
    error PayloadTooSmall();

    error NotImplemented();
    error ExclusiveTo(bytes32 solver);

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

    function _fill(bytes32 orderId, bytes calldata output, bytes32 proposedSolver) internal virtual returns (bytes32) {
        uint256 amount = _resolveOutput(output, proposedSolver);
        return _fill(orderId, output, amount, proposedSolver);
    }

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

    function _resolveOutput(bytes calldata output, bytes32 solver) internal view returns (uint256 amount) {
        uint16 callDataLength = uint16(bytes2(output[0xc6:0xc8]));
        amount = output.amount();

        bytes calldata fulfilmentData = output.contextData();

        uint16 fulfillmentLength = uint16(fulfilmentData.length);

        if (fulfillmentLength == 0) return amount;

        uint256 fulfilmentOffset = 0xc6 + 0x2 + callDataLength + 0x2; // callData offset, 2 bytes for call size,
            // calldata length, 2 bytes for context size

        bytes1 orderType = fulfilmentData.orderType();

        if (orderType == OutputFillLib.LIMIT_ORDER && fulfillmentLength == 1) return amount;
        if (orderType == OutputFillLib.DUTCH_AUCTION) {
            (uint32 startTime, uint32 stopTime, uint256 slope) = fulfilmentData.getDutchAuctionData();
            return _dutchAuctionSlope(amount, slope, startTime, stopTime);
        }

        if (orderType == OutputFillLib.EXCLUSIVE_LIMIT_ORDER) {
            (bytes32 exclusiveFor, uint32 startTime) = fulfilmentData.getExclusiveLimitOrderData();
            if (startTime > block.timestamp && exclusiveFor != solver) revert ExclusiveTo(exclusiveFor);
            return amount;
        }
        if (orderType == OutputFillLib.EXCLUSIVE_DUTCH_AUCTION) {
            (bytes32 exclusiveFor, uint32 startTime, uint32 stopTime, uint256 slope) =
                fulfilmentData.getExclusiveDutchAuctionData();
            if (startTime > block.timestamp && exclusiveFor != solver) revert ExclusiveTo(exclusiveFor);
            return _dutchAuctionSlope(amount, slope, startTime, stopTime);
        }
        revert NotImplemented();
    }

    // --- External Solver Interface --- //

    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external returns (bytes32) {
        // TODO: handle fill deadline
        bytes32 proposedSolver;
        uint48 fillDeadline = originData.fillDeadline();
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
        bytes32 oracle = output.oracle();
        bytes32 settler = output.settler();
        uint256 chainId = output.chainId();
        bytes32 token = output.token();
        uint256 amount = output.amount();
        bytes32 recipientBytes = output.recipient();

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

        bytes calldata callbackData = output.callbackData();

        if (callbackData.length > 0) IOIFCallback(recipient).outputFilled(token, outputAmount, callbackData);

        emit OutputFilled(orderId, proposedSolver, fillTimestamp, output, outputAmount);

        return fillRecordHash;
    }

    // -- Batch Solving -- //

    function fillOrderOutputs(bytes32 orderId, bytes[] calldata outputs, bytes calldata fillerData) external {
        bytes32 proposedSolver;
        assembly ("memory-safe") {
            proposedSolver := calldataload(fillerData.offset)
        }

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
