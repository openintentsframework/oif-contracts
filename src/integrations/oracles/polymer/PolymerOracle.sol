// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

    /// @dev Helper to take a substring of `data` from `start` (inclusive) with length `len`.
    function _substring(
        bytes memory data,
        uint256 start,
        uint256 len
    ) internal pure returns (string memory) {
        require(start + len <= data.length, "Substring out of bounds");
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            result[i] = data[start + i];
        }
        return string(result);
    }

    /// @dev Converts a single hex character into its value.
    function _fromHexChar(
        uint8 c
    ) internal pure returns (uint8) {
        if (c >= 48 && c <= 57) {
            // '0' - '9'
            return c - 48;
        } else if (c >= 97 && c <= 102) {
            // 'a' - 'f'
            return 10 + (c - 97);
        } else if (c >= 65 && c <= 70) {
            // 'A' - 'F'
            return 10 + (c - 65);
        } else {
            revert("Invalid hex char");
        }
    }

    /// @dev Parses a hex string (with or without 0x prefix) into a bytes32.
    function _hexStringToBytes32(
        string memory str
    ) internal pure returns (bytes32) {
        bytes memory s = bytes(str);
        uint256 start = 0;

        // Optional 0x / 0X prefix.
        if (s.length >= 2 && s[0] == "0" && (s[1] == "x" || s[1] == "X")) start = 2;

        require(s.length == start + 64, "Invalid hex length");

        bytes32 result;
        for (uint256 i = 0; i < 32; ++i) {
            uint8 high = _fromHexChar(uint8(s[start + 2 * i])); // first hex char
            uint8 low = _fromHexChar(uint8(s[start + 2 * i + 1])); // second hex char
            result |= bytes32(uint256(uint8((high << 4) | low)) << (248 - i * 8)); // Combine without overwriting
        }
        return result;
    }

    /// @dev Returns true if `data` contains `prefix` starting at `start`.
    function _hasPrefix(
        bytes memory data,
        bytes memory prefix,
        uint256 start
    ) internal pure returns (bool) {
        if (data.length < start + prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; ++i) {
            if (data[start + i] != prefix[i]) return false;
        }
        return true;
    }

    /// @dev Validates and parses a single Solana log line.
    /// Expects the format: "Application: 0x<64 hex>, PayloadHash: 0x<64 hex>".
    /// Returns (true, application, payloadHash) if the line matches, otherwise (false, 0, 0).
    function _isValidLog(
        bytes memory applicationSeparator,
        bytes memory payloadHashSeparator,
        uint256 expectedLen,
        bytes memory logBytes
    ) internal pure returns (bool isValid, bytes32 application, bytes32 payloadHash) {
        // Quick length check
        if (logBytes.length != expectedLen) return (false, bytes32(0), bytes32(0));

        // Must start with "Application: "
        if (!_hasPrefix(logBytes, applicationSeparator, 0)) return (false, bytes32(0), bytes32(0));

        // Application: "0x" + 64 hex chars → 66 characters
        uint256 idx = applicationSeparator.length;
        string memory applicationStr = _substring(logBytes, idx, 66);
        idx += 66;

        // Expect exact ", PayloadHash: " separator
        if (!_hasPrefix(logBytes, payloadHashSeparator, idx)) return (false, bytes32(0), bytes32(0));
        idx += payloadHashSeparator.length;

        // PayloadHash: "0x" + 64 hex chars → 66 characters
        string memory payloadHashStr = _substring(logBytes, idx, 66);
        idx += 66;

        // Sanity: must be at end of line
        if (idx != logBytes.length) return (false, bytes32(0), bytes32(0));

        // Parse hex strings into bytes32
        application = _hexStringToBytes32(applicationStr);
        payloadHash = _hexStringToBytes32(payloadHashStr);
        isValid = true;
    }

    /**
     * @dev the log emitted is in the format:
     *  "Prove: program: <programID>, Application: <application>, PayloadHash: <payloadHash>"
     *  The prover validates it and returns a log in the format:
     *  "Application: <application>, PayloadHash: <payloadHash>"
     */
    function _processSolanaMessage(
        bytes calldata proof
    ) internal {
        (uint32 chainId, bytes32 returnedProgramID, string[] memory logMessages) =
            CROSS_L2_PROVER.validateSolLogs(proof);
        require(chainId == 2, "Must be from Solana");

        uint256 remoteChainId = _getChainId(uint256(chainId));

        bytes memory appSep = bytes("Application: ");
        bytes memory hashSep = bytes(", PayloadHash: ");

        uint256 hexLen = 66; // 32 bytes as hex plus "0x" prefix
        uint256 expectedLen = appSep.length + hexLen + hashSep.length + hexLen;

        bool foundValidLog = false;
        for (uint256 i = 0; i < logMessages.length; i++) {
            bytes memory logBytes = bytes(logMessages[i]);

            (bool ok, bytes32 application, bytes32 payloadHash) = _isValidLog(appSep, hashSep, expectedLen, logBytes);
            if (!ok) continue;

            _attestations[remoteChainId][returnedProgramID][application][payloadHash] = true;
            emit OutputProven(remoteChainId, returnedProgramID, application, payloadHash);

            foundValidLog = true;
            break;
        }

        require(foundValidLog, "No valid log message found in proof");
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
