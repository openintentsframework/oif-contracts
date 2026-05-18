// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "../libs/LibAddress.sol";

import { EIP712 } from "openzeppelin/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "openzeppelin/utils/cryptography/SignatureChecker.sol";

import { IInputCallback } from "../interfaces/IInputCallback.sol";
import { IInputOracle } from "../interfaces/IInputOracle.sol";

import { AllowOpenType } from "./types/AllowOpenType.sol";
import { MandateOutput } from "./types/MandateOutputType.sol";

import { MandateOutputEncodingLib } from "../libs/MandateOutputEncodingLib.sol";
import { MandateOutput } from "./types/MandateOutputType.sol";

/**
 * @title Base Input Settler
 * @notice Defines common logic that can be reused by other input settlers to support a variety of asset management
 * schemes within the Open Intents Framework (OIF). This abstract contract provides the foundational building blocks
 * for cross-chain intent settlement, including validation, timestamp management, and proof verification.
 */
abstract contract InputSettlerBase is EIP712 {
    using LibAddress for address;
    using LibAddress for bytes32;

    /**
     * @dev Timestamp has passed.
     */
    error TimestampPassed();
    /**
     * @dev Timestamp has not passed.
     */
    error TimestampNotPassed();
    /**
     * @dev Wrong chain.
     */
    error WrongChain(uint256 expected, uint256 actual);
    /**
     * @dev Invalid signer.
     */
    error InvalidSigner();
    /**
     * @dev Filled too late.
     */
    error FilledTooLate(uint32 expected, uint32 actual);
    /**
     * @dev Invalid timestamp length.
     */
    error InvalidTimestampLength();
    /**
     * @dev No destination.
     */
    error NoDestination();
    /**
     * @dev Fill deadline is after expiry deadline.
     */
    error FillDeadlineAfterExpiry(uint32 fillDeadline, uint32 expires);

    /**
     * @notice Emitted when an order is finalised.
     * @param orderId The order identifier.
     * @param solver The solver.
     * @param destination The destination.
     */
    event Finalised(bytes32 indexed orderId, bytes32 solver, bytes32 destination);

    struct SolveParams {
        uint32 timestamp;
        bytes32 solver;
    }

    /**
     * @notice Returns the domain separator for the EIP712 contract.
     * @return The domain separator.
     */
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // --- Validation --- //

    /**
     * @notice Checks that a timestamp has not expired.
     * @param timestamp The timestamp to validate that it is at least equal to block.timestamp
     */
    function _validateTimestampHasNotPassed(
        uint32 timestamp
    ) internal view {
        if (block.timestamp >= timestamp) revert TimestampPassed();
    }

    /**
     * @notice Checks that a timestamp has passed.
     * @param timestamp The timestamp to validate that it is not less than block.timestamp
     */
    function _validateTimestampHasPassed(
        uint32 timestamp
    ) internal view {
        if (block.timestamp <= timestamp) revert TimestampNotPassed();
    }

    /**
     * @notice Checks that fillDeadline is before or equal to expires.
     * @param fillDeadline The fill deadline timestamp to validate.
     * @param expires The expiry timestamp to validate against.
     */
    function _validateFillDeadlineBeforeExpiry(
        uint32 fillDeadline,
        uint32 expires
    ) internal pure {
        if (fillDeadline > expires) revert FillDeadlineAfterExpiry(fillDeadline, expires);
    }

    /**
     * @notice Checks that this is the right chain for the order.
     * @param chainId Expected chainId for order. Will be checked against block.chainid
     */
    function _validateInputChain(
        uint256 chainId
    ) internal view {
        if (chainId != block.chainid) revert WrongChain(chainId, block.chainid);
    }

    /**
     * @notice Validates that the rightmost 20 bytes are not 0.
     * @param destination Destination of the funds
     */
    function _validateDestination(
        bytes32 destination
    ) internal pure {
        bool isZero;
        // Check if the rightmost 20 bytes are not all 0. That is a stronger check than the entire 32 bytes.
        assembly ("memory-safe") {
            isZero := iszero(shl(96, destination))
        }
        if (isZero) revert NoDestination();
    }

    // --- Timestamp Helpers --- //

    /**
     * @param solveParams Array of SolveParams.
     * @return timestamp Largest element of timestamps.
     */
    function _maxTimestamp(
        SolveParams[] calldata solveParams
    ) internal pure returns (uint256 timestamp) {
        timestamp = solveParams[0].timestamp;

        uint256 numTimestamps = solveParams.length;
        for (uint256 i = 1; i < numTimestamps; ++i) {
            uint32 nextTimestamp = solveParams[i].timestamp;
            if (timestamp < nextTimestamp) timestamp = nextTimestamp;
        }
    }

    /**
     * @param solveParams Array of SolveParams.
     * @return timestamp Smallest element of timestamps.
     */
    function _minTimestamp(
        SolveParams[] calldata solveParams
    ) internal pure returns (uint256 timestamp) {
        timestamp = solveParams[0].timestamp;

        uint256 numTimestamps = solveParams.length;
        for (uint256 i = 1; i < numTimestamps; ++i) {
            uint32 nextTimestamp = solveParams[i].timestamp;
            if (timestamp > nextTimestamp) timestamp = nextTimestamp;
        }
    }

    // --- External Claimant --- //

    /**
     * @notice Check for a signed message by an order owner to allow someone else to redeem an order.
     * @dev See AllowOpenType.sol
     * @param orderId A unique identifier for an order.
     * @param orderOwner Owner of the order, and signer of orderOwnerSignature.
     * @param nextDestination New destination.
     * @param call An external call required by orderOwner.
     * @param orderOwnerSignature EIP712 Signature of AllowOpen by orderOwner.
     */
    function _allowExternalClaimant(
        bytes32 orderId,
        address orderOwner,
        bytes32 nextDestination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) internal view {
        bytes32 digest = _hashTypedDataV4(AllowOpenType.hashAllowOpen(orderId, nextDestination, call));
        bool isValid = SignatureChecker.isValidSignatureNowCalldata(orderOwner, digest, orderOwnerSignature);
        if (!isValid) revert InvalidSigner();
    }

    function _proofPayloadHash(
        bytes32 orderId,
        bytes32 solver,
        uint32 timestamp,
        MandateOutput calldata output
    ) internal pure returns (bytes32 outputHash) {
        return keccak256(MandateOutputEncodingLib.encodeFillDescription(solver, orderId, timestamp, output));
    }

    /**
     * @notice Check if a series of outputs has been proven.
     * @dev Can take a list of solvers. Should be used as a secure alternative to _validateFills
     * if someone filled one of the outputs.
     */
    function _validateFills(
        uint32 fillDeadline,
        address inputOracle,
        MandateOutput[] calldata outputs,
        bytes32 orderId,
        SolveParams[] calldata solveParams
    ) internal view {
        uint256 numOutputs = outputs.length;
        uint256 numTimestamps = solveParams.length;
        if (numTimestamps != numOutputs) revert InvalidTimestampLength();

        bytes memory proofSeries = new bytes(32 * 4 * numOutputs);
        for (uint256 i; i < numOutputs; ++i) {
            uint32 outputFilledAt = solveParams[i].timestamp;
            if (fillDeadline < outputFilledAt) revert FilledTooLate(fillDeadline, outputFilledAt);
            MandateOutput calldata output = outputs[i];
            bytes32 payloadHash = _proofPayloadHash(orderId, solveParams[i].solver, outputFilledAt, output);

            uint256 chainId = output.chainId;
            bytes32 outputOracle = output.oracle;
            bytes32 outputSettler = output.settler;
            assembly ("memory-safe") {
                let offset := add(add(proofSeries, 0x20), mul(i, 0x80))
                mstore(offset, chainId)
                mstore(add(offset, 0x20), outputOracle)
                mstore(add(offset, 0x40), outputSettler)
                mstore(add(offset, 0x60), payloadHash)
            }
        }
        IInputOracle(inputOracle).efficientRequireProven(proofSeries);
    }
}
