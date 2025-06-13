// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IOIFCallback } from "../interfaces/IOIFCallback.sol";
import { IPayloadCreator } from "../interfaces/IPayloadCreator.sol";

import { LibAddress } from "../libs/LibAddress.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../libs/OutputVerificationLib.sol";

import { BaseOracle } from "../oracles/BaseOracle.sol";

/**
 * @notice Base Output Settler implementing logic for settling outputs.
 * Does not support native coins.
 * This base output settler implements logic to work as both a PayloadCreator (for oracles) and as an oracle itself.
 */
abstract contract BaseOutputSettler is IPayloadCreator, BaseOracle {
    error FillDeadline();
    error FilledBySomeoneElse(bytes32 solver);
    error ZeroValue();

    using LibAddress for address;

    /**
     * @notice Sets outputs as filled by their solver identifier, such that outputs won't be filled twice.
     * @dev Is not used for validating payloads, BaseOracle::_attestations is used instead.
     */
    mapping(bytes32 orderId => mapping(bytes32 outputHash => bytes32 solver)) public filledOutputs;

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
     * @return actualSolver Solver that filled the order. Tokens are only collected if equal to proposedSolver.
     */
    function _fill(
        bytes32 orderId,
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) internal virtual returns (bytes32);

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
     * @return bytes32 Solver that filled the order. Tokens are only collected if equal to proposedSolver.
     */
    function _fill(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 outputAmount,
        bytes32 proposedSolver
    ) internal virtual returns (bytes32) {
        if (proposedSolver == bytes32(0)) revert ZeroValue();
        OutputVerificationLib._isThisChain(output.chainId);
        OutputVerificationLib._isThisOutputSettler(output.settler);

        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHash(output);
        bytes32 existingSolver = filledOutputs[orderId][outputHash];
        if (existingSolver != bytes32(0)) return existingSolver; // Early return if already solved.
        // The above and below lines act as a local re-entry check.
        filledOutputs[orderId][outputHash] = proposedSolver;

        // Set the output attestation as true. This allows the output settler to act as an oracle. Note that the payload
        // contains the current timestamp. This timestamp needs to be collected from the event (or tx) to be able to
        // reproduce the payload(hash)
        bytes32 dataHash = keccak256(
            MandateOutputEncodingLib.encodeFillDescription(proposedSolver, orderId, uint32(block.timestamp), output)
        );
        _attestations[block.chainid][address(this).toIdentifier()][address(this).toIdentifier()][dataHash] = true;

        // Storage has been set. Fill the output.
        address recipient = address(uint160(uint256(output.recipient)));
        SafeTransferLib.safeTransferFrom(address(uint160(uint256(output.token))), msg.sender, recipient, outputAmount);
        if (output.call.length > 0) IOIFCallback(recipient).outputFilled(output.token, outputAmount, output.call);

        emit OutputFilled(orderId, proposedSolver, uint32(block.timestamp), output);
        return proposedSolver;
    }

    // --- External Solver Interface --- //

    /**
     * @dev External fill interface for filling a single order.
     * @param fillDeadline If the transaction is executed after this timestamp, the call will fail.
     * @param orderId Input chain order identifier. Is used as is, not checked for validity.
     * @param output Given output to fill. Is expected to belong to a greater order identified by orderId.
     * @param proposedSolver Solver identifier to be sent to input chain.
     * @return bytes32 Solver that filled the order. Tokens are only collected if equal to proposedSolver.
     */
    function fill(
        uint32 fillDeadline,
        bytes32 orderId,
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) external virtual returns (bytes32) {
        if (fillDeadline < block.timestamp) revert FillDeadline();
        return _fill(orderId, output, proposedSolver);
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

        bytes32 actualSolver = _fill(orderId, outputs[0], proposedSolver);
        if (actualSolver != proposedSolver) revert FilledBySomeoneElse(actualSolver);

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
     * @notice Helper function to check whether a payload hash is valid.
     * @param payloadHash keccak256 hash of the relevant payload.
     * @return bool Whether or not the payload has been recorded as filled.
     */
    function _isPayloadValid(
        bytes32 payloadHash
    ) internal view virtual returns (bool) {
        return _attestations[block.chainid][address(this).toIdentifier()][address(this).toIdentifier()][payloadHash];
    }

    /**
     * @notice Returns whether a set of payload hashes have been approved by this contract.
     */
    function arePayloadsValid(
        bytes32[] calldata payloadHashes
    ) external view returns (bool) {
        uint256 numPayloads = payloadHashes.length;
        bool accumulator = true;
        for (uint256 i; i < numPayloads; ++i) {
            accumulator = accumulator && _isPayloadValid(payloadHashes[i]);
        }
        return accumulator;
    }
}
