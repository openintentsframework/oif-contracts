// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { ICatalystCallback } from "../interfaces/ICatalystCallback.sol";
import { IPayloadValidator } from "../interfaces/IPayloadValidator.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../libs/MandateOutputEncodingLib.sol";

/**
 * @notice Base Filler implementation that implements common and shared logic between filler implementations.
 */
abstract contract BaseFiller is IPayloadValidator {
    error FillDeadline();
    error AlreadyFilled(bytes32 orderId, bytes32 outputHash);
    error WrongChain(uint256 expected, uint256 actual);
    error WrongRemoteFiller(bytes32 addressThis, bytes32 expected);
    error ZeroValue();

    /// @notice Maps an output to the hash of its fill-description
    mapping(bytes32 orderId => mapping(bytes32 outputHash => bytes32 payloadHash)) internal _fillRecords;

    event OutputFilled(bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output);

    /**
     * @dev Fill implementation evaluating the incoming order.
     * Is expected to call _fill(bytes32,MandateOutput,uint256,bytes32)
     * @param orderId Global identifier for the filled order. Is used as is, not checked for validity.
     * @param output The given output to fill. Is expected to belong to a greater order identified by orderId
     * @param proposedSolver Solver identifier set as the filler if the order has not already been filled.
     */
    function _fill(bytes32 orderId, MandateOutput calldata output, bytes32 proposedSolver) internal virtual;

    /**
     * @notice Verifies & Fills an order.
     * If an order has already been filled given the output & fillDeadline, then this function
     * doesn't "re"fill the order but returns early. Thus this function can also be used to verify that an order has
     * been filled.
     * @dev Does not automatically submit the order (send the proof).
     * The implementation strategy (verify then fill) means that an order with repeat outputs
     * (say 1 Ether to Alice & 1 Ether to Alice) can be filled by sending 1 Ether to Alice ONCE.
     * !Don't make orders with repeat outputs. This is true for any oracles.!
     * This function implements a protection against sending proofs from third-party oracles.
     * Only proofs that have this as the correct chain and remoteOracleAddress can be sent to other oracles.
     * @param orderId Global identifier for the filled order. Is used as is, not checked for validity.
     * @param output Given output to fill. Is expected to belong to a greater order identified by orderId
     * @param outputAmount True amount to fill after order evaluation. Will be instead of output.amount.
     * @param proposedSolver Solver identifier set as the filler if the order has not already been filled.
     */
    function _fill(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 outputAmount,
        bytes32 proposedSolver
    ) internal virtual {
        if (proposedSolver == bytes32(0)) revert ZeroValue();
        // Validate order context. This lets us ensure that this filler is the correct filler for the output.
        _validateChain(output.chainId);
        _validateRemoteFiller(output.remoteFiller);

        // Get hash of output.
        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHash(output);

        // Check if already filled
        bytes32 existing = _fillRecords[orderId][outputHash];
        // TODO: Before we didn't revert. Maybe we shouldn't now.
        if (existing != bytes32(0)) revert AlreadyFilled(orderId, outputHash);

        // Build payload hash for attestation
        bytes32 payloadHash = keccak256(
            MandateOutputEncodingLib.encodeFillDescription(proposedSolver, orderId, uint32(block.timestamp), output)
        );

        // Store the fill record
        _fillRecords[orderId][outputHash] = payloadHash;

        // Load order description.
        address recipient = address(uint160(uint256(output.recipient)));
        address token = address(uint160(uint256(output.token)));

        // Collect tokens from the user. If this fails, then the call reverts and
        // the proof is not set to true.
        SafeTransferLib.safeTransferFrom(token, msg.sender, recipient, outputAmount);

        // If there is an external call associated with the fill, execute it.
        uint256 remoteCallLength = output.remoteCall.length;
        if (remoteCallLength > 0) {
            ICatalystCallback(recipient).outputFilled(output.token, outputAmount, output.remoteCall);
        }

        emit OutputFilled(orderId, proposedSolver, uint32(block.timestamp), output);
    }

    // --- Solver Interface --- //

    /**
     * @dev External fill interface for filling a single order.
     * Is expected to call _fill(bytes32,MandateOutput,uint256,bytes32)
     * @param fillDeadline If the transaction is executed after this timestamp, the call will fail. For orders with
     * either a expiry or fillDeadline this should be used to ensure prompt execution.
     * @param orderId Global identifier for the filled order. Is used as is, not checked for validity.
     * @param output The given output to fill. Is expected to belong to a greater order identified by orderId.
     * @param proposedSolver Solver identifier set as the filler if the order has not already been filled.
     */
    function fill(
        uint32 fillDeadline,
        bytes32 orderId,
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) external {
        if (fillDeadline < block.timestamp) revert FillDeadline();

        _fill(orderId, output, proposedSolver);
    }

    // --- Batch Solving --- //

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
     * @param orderId Global identifier for the filled order. Is used as is, not checked for validity.
     * @param outputs The given outputs to fill. Ensure that the **first** output of the order is also the first output
     * of this call.
     * @param proposedSolver Solver identifier set as the filler if the order has not already been filled.
     */
    function fillBatch(
        uint32 fillDeadline,
        bytes32 orderId,
        MandateOutput[] calldata outputs,
        bytes32 proposedSolver
    ) external {
        if (fillDeadline < block.timestamp) revert FillDeadline();

        // TODO: The check for the solver does seem important.
        _fill(orderId, outputs[0], proposedSolver);

        uint256 numOutputs = outputs.length;
        for (uint256 i = 1; i < numOutputs; ++i) {
            _fill(orderId, outputs[i], proposedSolver);
        }
    }

    // --- External Calls --- //

    /**
     * @notice Allows estimating the gas used for an external call.
     * @dev To call, set msg.sender to address(0).
     * This call can never be executed on-chain. It should also be noted that application can cheat and implement
     * special logic for tx.origin == 0.
     */
    function call(uint256 trueAmount, MandateOutput calldata output) external {
        // Disallow calling on-chain.
        require(msg.sender == address(0));

        ICatalystCallback(address(uint160(uint256(output.recipient)))).outputFilled(
            output.token, trueAmount, output.remoteCall
        );
    }

    //-- Helpers --//

    /**
     * @param chainId Expected chain id. Validated to match the chain's chainId (block.chainId)
     * @dev We use the chain's canonical id rather than a messaging protocol id for clarity.
     */
    function _validateChain(
        uint256 chainId
    ) internal view {
        if (chainId != block.chainid) revert WrongChain(uint256(chainId), block.chainid);
    }

    /**
     * @notice Validate that the remote oracle address is this oracle.
     * @dev For some oracles, it might be required that you "cheat" and change the encoding here.
     * Don't worry (or do worry) because the other side loads the payload as bytes32(bytes).
     */
    function _validateRemoteFiller(
        bytes32 remoteFiller
    ) internal view virtual {
        if (bytes32(uint256(uint160(address(this)))) != remoteFiller) {
            revert WrongRemoteFiller(bytes32(uint256(uint160(address(this)))), remoteFiller);
        }
    }

    /**
     * @notice Check if a series of fill records are valid.
     * @param fills Array of fill records to validate
     * @return bool Whether all fill records are valid
     */
    function arePayloadsValid(
        FillRecord[] calldata fills
    ) external view override returns (bool) {
        uint256 numFills = fills.length;
        for (uint256 i; i < numFills; ++i) {
            FillRecord calldata fillRecord = fills[i];
            if (_fillRecords[fillRecord.orderId][fillRecord.outputHash] != fillRecord.payloadHash) return false;
        }
        return true;
    }
}
