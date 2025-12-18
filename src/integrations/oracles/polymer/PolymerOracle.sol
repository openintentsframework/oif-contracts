// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { HexBytes } from "../../../libs/HexBytesLib.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
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
    error NoValidLogFound();

    uint256 constant SOLANA_POLYMER_CHAIN_ID = 2;
    bytes constant SOLANA_APPLICATION_SEPARATOR = bytes("Application: ");
    bytes constant SOLANA_PAYLOAD_HASH_SEPARATOR = bytes(", PayloadHash: ");
    uint256 constant SOLANA_HEX_STRING_LENGTH = 66; // 32 bytes as hex plus "0x" prefix
    // 13 ("Application: ") + 66 (0x + 64 hex chars) + 15 (", PayloadHash: ") + 66 (0x + 64 hex chars) = 160
    uint256 constant SOLANA_EXPECTED_LOG_LENGTH = 13 + 66 + 15 + 66;

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

    /// @dev Validates and parses a single Solana log line.
    /// Expects the format: "Application: 0x<64 hex>, PayloadHash: 0x<64 hex>".
    /// Returns (application, payloadHash) if the log is valid, otherwise (0, 0).
    function _isValidLog(
        bytes memory logBytes
    ) internal pure returns (bytes32 application, bytes32 payloadHash) {
        // Quick length check
        if (logBytes.length != SOLANA_EXPECTED_LOG_LENGTH) return (bytes32(0), bytes32(0));

        if (!HexBytes.hasPrefix(logBytes, SOLANA_APPLICATION_SEPARATOR, 0)) return (bytes32(0), bytes32(0));

        // Application: "0x" + 64 hex chars → 66 characters
        uint256 idx = SOLANA_APPLICATION_SEPARATOR.length;
        bytes memory applicationHexBytes = HexBytes.sliceFromBytes(logBytes, idx, 66);
        idx += 66;

        // Expect exact ", PayloadHash: " separator
        if (!HexBytes.hasPrefix(logBytes, SOLANA_PAYLOAD_HASH_SEPARATOR, idx)) return (bytes32(0), bytes32(0));
        idx += SOLANA_PAYLOAD_HASH_SEPARATOR.length;

        // PayloadHash: "0x" + 64 hex chars → 66 characters
        bytes memory payloadHexBytes = HexBytes.sliceFromBytes(logBytes, idx, 66);
        idx += 66;

        // Sanity: must be at end of line
        if (idx != logBytes.length) return (bytes32(0), bytes32(0));

        // Parse hex bytes into bytes32
        application = HexBytes.hexBytesToBytes32(applicationHexBytes);
        payloadHash = HexBytes.hexBytesToBytes32(payloadHexBytes);
    }

    /**
     * @dev The Solana program emits a log in the format:
     *  "Prove: program: <programID>, Application: <application>, PayloadHash: <payloadHash>"
     *  where `<application>` and `<payloadHash>` are 32-byte values encoded as hex strings:
     *  the ASCII characters `"0x"` followed by 64 lowercase hex characters (i.e. 0x + 32 bytes).
     */
    function _processSolanaMessage(
        bytes calldata proof
    ) internal {
        (uint32 chainId, bytes32 returnedProgramID, string[] memory logMessages) =
            CROSS_L2_PROVER.validateSolLogs(proof);

        require(chainId == SOLANA_POLYMER_CHAIN_ID, NotSolanaMessage());

        uint256 remoteChainId = _getChainId(uint256(chainId));

        bool foundValidLog = false;
        for (uint256 i = 0; i < logMessages.length; i++) {
            bytes memory logBytes = bytes(logMessages[i]);

            (bytes32 application, bytes32 payloadHash) = _isValidLog(logBytes);
            // It is okay to do a single check here since both of the return values are bytes32(0) if the log is
            // invalid.
            if (application == bytes32(0)) continue;

            _attestations[remoteChainId][returnedProgramID][application][payloadHash] = true;
            emit OutputProven(remoteChainId, returnedProgramID, application, payloadHash);

            foundValidLog = true;
            // Only one valid log per proof is allowed.
            break;
        }

        require(foundValidLog, NoValidLogFound());
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
