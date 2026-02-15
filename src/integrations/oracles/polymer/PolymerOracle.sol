// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "../../../libs/LibAddress.sol";
import { Base64 } from "openzeppelin/utils/Base64.sol";
import { Bytes } from "openzeppelin/utils/Bytes.sol";

import { MandateOutput, MandateOutputEncodingLib } from "../../../libs/MandateOutputEncodingLib.sol";

import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { OutputSettlerBase } from "../../../output/OutputSettlerBase.sol";
import { ICrossL2ProverV2 } from "./external/interfaces/ICrossL2ProverV2.sol";

/**
 * @notice Polymer Oracle.
 * Polymer uses the fill event to reconstruct the payload for verification instead of sending messages cross-chain.
 */
contract PolymerOracle is BaseInputOracle {
    using LibAddress for address;

    error WrongEventSignature();
    error NotSolanaMessage();
    error InvalidSolanaMessage();
    error SolanaProgramIdMismatch(bytes32 returnedProgramId, bytes32 messageProgramId);

    uint256 constant SOLANA_POLYMER_CHAIN_ID = 2;

    ICrossL2ProverV2 CROSS_L2_PROVER;

    constructor(
        address crossL2Prover
    ) {
        CROSS_L2_PROVER = ICrossL2ProverV2(crossL2Prover);
    }

    function _getChainId(
        uint256 protocolId
    ) internal view virtual returns (uint256 chainId) {
        return protocolId;
    }

    /// ************** EVM Processing ************** ///

    function _proofPayloadHash(
        bytes32 orderId,
        bytes32 solver,
        uint32 timestamp,
        MandateOutput memory mandateOutput
    ) internal pure returns (bytes32 outputHash) {
        return outputHash =
            keccak256(MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, timestamp, mandateOutput));
    }

    function _processEvmMessage(
        bytes calldata proof
    ) internal {
        (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData) =
            CROSS_L2_PROVER.validateEvent(proof);

        // While it is unlikely that an event will be emitted matching the data pattern we have, validate the event
        // signature.
        bytes32 eventSignature = bytes32(Bytes.slice(topics, 0, 32));
        if (eventSignature != OutputSettlerBase.OutputFilled.selector) revert WrongEventSignature();

        // OrderId is topic[1] which is 32 to 64 bytes.
        bytes32 orderId = bytes32(Bytes.slice(topics, 32, 64));

        (bytes32 solver, uint32 timestamp, MandateOutput memory output,) =
            abi.decode(unindexedData, (bytes32, uint32, MandateOutput, uint256));

        bytes32 payloadHash = _proofPayloadHash(orderId, solver, timestamp, output);

        // Convert the Polymer ChainID into the canonical chainId.
        uint256 remoteChainId = _getChainId(uint256(chainId));

        bytes32 application = emittingContract.toIdentifier();
        _attestations[remoteChainId][address(this).toIdentifier()][application][payloadHash] = true;

        emit OutputProven(remoteChainId, address(this).toIdentifier(), application, payloadHash);
    }

    /// ************** Solana Processing ************** ///

    /**
     * @dev Solana logs are passed in as base64-encoded bytes.
     *
     * The decoded bytes are expected to be:
     * - bytes[0:32]   = `messageProgramId` (bytes32) // program id the message claims to be from
     * - bytes[32:64]  = `emitter` (bytes32)          // remote identifier
     * - bytes[64:96]  = `application` (bytes32)      // application/settler identifier
     * - bytes[96:]    = `payload` (bytes)            // raw payload bytes (dynamic length)
     */
    function _processSolanaMessage(
        bytes calldata proof
    ) internal {
        (uint32 chainId, bytes32 returnedProgramId, string[] memory logMessages) =
            CROSS_L2_PROVER.validateSolLogs(proof);

        require(chainId == SOLANA_POLYMER_CHAIN_ID, NotSolanaMessage());

        uint256 remoteChainId = _getChainId(uint256(chainId));

        for (uint256 i = 0; i < logMessages.length; i++) {
            bytes memory logBytes = Base64.decode(logMessages[i]);

            if (logBytes.length < 96) revert InvalidSolanaMessage();
            bytes32 messageProgramId = bytes32(Bytes.slice(logBytes, 0, 32));
            // Ensure the intended message came from the expected program.
            if (messageProgramId != returnedProgramId) {
                revert SolanaProgramIdMismatch(returnedProgramId, messageProgramId);
            }

            bytes32 emitter = bytes32(Bytes.slice(logBytes, 32, 64));
            bytes32 application = bytes32(Bytes.slice(logBytes, 64, 96));
            bytes32 payloadHash = keccak256(Bytes.slice(logBytes, 96, logBytes.length));

            _attestations[remoteChainId][emitter][application][payloadHash] = true;

            emit OutputProven(remoteChainId, emitter, application, payloadHash);
        }
    }

    function receiveMessage(
        bytes calldata proof
    ) external {
        _processEvmMessage(proof);
    }

    function receiveMessage(
        bytes[] calldata proofs
    ) external {
        uint256 numProofs = proofs.length;
        for (uint256 i; i < numProofs; ++i) {
            _processEvmMessage(proofs[i]);
        }
    }

    /**
     * @notice Processes a single Solana proof and updates the attestation state.
     * @param proof The proof data from Solana to be processed.
     */
    function receiveSolanaMessage(
        bytes calldata proof
    ) external {
        _processSolanaMessage(proof);
    }

    /**
     * @notice Processes multiple Solana proofs and updates the attestation state for each.
     * @param proofs An array of proof data from Solana to be processed.
     */
    function receiveSolanaMessage(
        bytes[] calldata proofs
    ) external {
        uint256 numProofs = proofs.length;
        for (uint256 i; i < numProofs; ++i) {
            _processSolanaMessage(proofs[i]);
        }
    }
}
