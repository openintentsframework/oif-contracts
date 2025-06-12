// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IOIFCallback } from "../interfaces/IOIFCallback.sol";
import { IPayloadCreator } from "../interfaces/IPayloadCreator.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../libs/OutputVerificationLib.sol";

import { IOracle } from "../interfaces/IOracle.sol";

/**
 * @notice Base Output Settler implementing logic for settling outputs.
 * @dev Does not support native coins.
 * @dev This base output settler implements logic to work as both a PayloadCreator (for oracles) and as an oracle
 * itself. The output settler can be used as an oracle for same-chain intents. This is achieved by setting the
 * `localOracle` of the order to the output settler address.
 */
abstract contract BaseOutputSettler is IPayloadCreator, IOracle {
    error FillDeadline();
    error AlreadyFilled(bytes32 orderId, bytes32 outputHash);
    error ZeroValue();

    /**
     * @notice Sets outputs as filled storing their payload hash, such that outputs won't be filled twice.
     * @dev Is not used for validating payloads, BaseOracle::_attestations is used instead.
     */
    mapping(bytes32 orderId => mapping(bytes32 outputHash => bytes32 payloadHash)) internal _fillRecords;

    /**
     * @notice Output has been filled.
     */
    event OutputFilled(bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output);

    /**
     * @dev Output Settlers are expected to implement pre-fill logic through this interface. It will be through external
     * fill interfaces exposed by the base logic.
     * Is expected to call _fill(bytes32,MandateOutput,uint256,bytes32)
     * @param orderId Input chain order identifier. Is used as is, not checked for validity.
     * @param output The given output to fill. Is expected to belong to a greater order identified by orderId
     * @param proposedSolver Solver identifier to be sent to input chain.
     */
    function _fill(bytes32 orderId, MandateOutput calldata output, bytes32 proposedSolver) internal virtual;

    /**
     * @notice Performs basic validation and fills output is unfilled.
     * If an order has already been filled given the output & fillDeadline, then this function does not "re"fill the
     * order but returns early.
     * @dev This fill function links the fill to the outcome of the external call. If the external call cannot execute,
     * the output is not fillable.
     * Does not automatically submit the order (send the proof).
     *                          !Do not make orders with repeated outputs!.
     * The implementation strategy (verify then fill) means that an order with repeat outputs
     * (say 1 Ether to Alice & 1 Ether to Alice) can be filled by sending 1 Ether to Alice ONCE.
     * @param orderId Input chain order identifier. Is used as is, not checked for validity.
     * @param output Given output to fill. Is expected to belong to a greater order identified by orderId
     * @param outputAmount Amount to fill after order evaluation. Will be instead of output.amount.
     * @param proposedSolver Solver identifier to be sent to input chain.
     */
    function _fill(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 outputAmount,
        bytes32 proposedSolver
    ) internal virtual {
        if (proposedSolver == bytes32(0)) revert ZeroValue();
        OutputVerificationLib._isThisChain(output.chainId);
        OutputVerificationLib._isThisOutputSettler(output.settler);

        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHash(output);
        bytes32 existing = _fillRecords[orderId][outputHash];

        if (existing != bytes32(0)) revert AlreadyFilled(orderId, outputHash);

        bytes32 payloadHash = keccak256(
            MandateOutputEncodingLib.encodeFillDescription(proposedSolver, orderId, uint32(block.timestamp), output)
        );
        _fillRecords[orderId][outputHash] = payloadHash;

        // Storage has been set. Fill the output.
        address recipient = address(uint160(uint256(output.recipient)));
        SafeTransferLib.safeTransferFrom(address(uint160(uint256(output.token))), msg.sender, recipient, outputAmount);
        if (output.call.length > 0) IOIFCallback(recipient).outputFilled(output.token, outputAmount, output.call);

        emit OutputFilled(orderId, proposedSolver, uint32(block.timestamp), output);
    }

    // --- External Solver Interface --- //

    /**
     * @dev External fill interface for filling a single order.
     * @param fillDeadline If the transaction is executed after this timestamp, the call will fail.
     * @param orderId Input chain order identifier. Is used as is, not checked for validity.
     * @param output Given output to fill. Is expected to belong to a greater order identified by orderId.
     * @param proposedSolver Solver identifier to be sent to input chain.
     */
    function fill(
        uint32 fillDeadline,
        bytes32 orderId,
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) external virtual {
        if (fillDeadline < block.timestamp) revert FillDeadline();
        _fill(orderId, output, proposedSolver);
    }

    // -- Batch Solving -- //

    /**
     * @dev This function aids to simplify solver selection from outputs fills.
     * The first output of an order will determine which solver "wins" the order.
     * This function fills the first output by proposedSolver. Otherwise reverts.
     * Then it attempts to fill the remaining outputs. If they have already been filled, it skips.
     * If any of the outputs fails to fill (because of tokens OR external call) the entire fill reverts.
     *
     * This function does not validate any part of the order but ensures multiple output orders
     * can be filled in a safer manner.
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
    ) external {
        if (fillDeadline < block.timestamp) revert FillDeadline();

        uint256 numOutputs = outputs.length;
        for (uint256 i = 0; i < numOutputs; ++i) {
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
     * @notice Check if a series of fill records are valid.
     * @param fills Encoded fill records to validate
     * @return bool Whether all fill records are valid
     */
    function arePayloadsValid(
        bytes calldata fills
    ) public view returns (bool) {
        // Decode the opaque bytes into FillRecord array
        FillRecord[] memory fillRecords = abi.decode(fills, (FillRecord[]));

        uint256 numFills = fillRecords.length;
        for (uint256 i; i < numFills; ++i) {
            FillRecord memory fillRecord = fillRecords[i];
            if (_fillRecords[fillRecord.orderId][fillRecord.outputHash] != fillRecord.payloadHash) return false;
        }
        return true;
    }

    // --- IOracle --- //

    function efficientRequireProven(
        bytes calldata proofSeries
    ) external view {
        if (!arePayloadsValid(proofSeries)) revert NotProven();
    }
}
