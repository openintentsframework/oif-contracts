// SPDX-License-Identifier: Apache-2.0
/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.8.15;

import { LightClientType } from "../../interfaces/IClientUpdates.sol";
import { ICrossL2ProverV2 } from "../../interfaces/ICrossL2ProverV2.sol";
import { ReceiptParser } from "../../libs/ReceiptParser.sol";

import { SequencerSignatureVerifierV2 } from "./SequencerSignatureVerifierV2.sol";

/**
 * @title CrossL2ProverV2
 * @notice A contract that validates cross-chain event proofs from Polymer's prove API
 * @notice Use NativeProver as a fallback.
 */
contract CrossL2ProverV2 is SequencerSignatureVerifierV2, ICrossL2ProverV2 {
    event Ping(); // Event to signal the initialization of the chain

    LightClientType public constant LIGHT_CLIENT_TYPE = LightClientType.SequencerLightClient; // Stored as a constant
        // for cheap on-chain use

    string public clientType;

    error InvalidProofRoot();

    constructor(
        string memory clientType_,
        address sequencer_,
        bytes32 chainId_
    ) SequencerSignatureVerifierV2(sequencer_, chainId_) {
        clientType = clientType_;
        emit Ping(); // Emit an event that can be proven on polymer as a health check
    }

    /**
     * @notice Validates an event proof from Polymer's prove api for a non-Solana chain.
     * @notice These proofs should be generated using https://proof.devnet.polymer.zone
     * @notice Use `validateSolLogs` for Solana proofs.
     * @param proof The proof bytes containing:
     *     //  +--------------------------------------------------+
     *     //  |  state root (32 bytes)                           | 0:32
     *     //  +--------------------------------------------------+
     *     //  |  signature (65 bytes)                            | 32:97
     *     //  +--------------------------------------------------+
     *     //  |  source chain ID (big endian, 4 bytes)           | 97:101
     *     //  +--------------------------------------------------+
     *     //  |  peptide height (big endian, 8 bytes)            | 101:109
     *     //  +--------------------------------------------------+
     *     //  |  source chain block height (big endian, 8 bytes) | 109:117
     *     //  +--------------------------------------------------+
     *     //  |  receipt index (big endian, 4 bytes)             | 117:121
     *     //  +--------------------------------------------------+
     *     //  |  event index (big endian, 4 bytes)               | 121:125
     *     //  +--------------------------------------------------+
     *     //  |  number of topics (1 byte)                       | 125
     *     //  +--------------------------------------------------+
     *     //  |  event data end (big endian, 2 bytes)            | 126:128
     *     //  +--------------------------------------------------+
     *     //  |  event emitter (contract address) (20 bytes)     | 128:148
     *     //  +--------------------------------------------------+
     *     //  |  topics (32 bytes * number of topics)            | 148 + 32 * number of topics: eventDatEnd
     *     //  +--------------------------------------------------+
     *     //  |  event data (x bytes)                            | eventDataEnd:
     *     //  +--------------------------------------------------+
     *     //  |  iavl proof (x bytes)                            |
     *     //  +--------------------------------------------------+
     * @return chainId The chain ID of the source chain
     * @return emittingContract The address of the contract that emitted the event
     * @return topics The event topics
     * @return unindexedData The unindexed event data
     */
    function validateEvent(
        bytes calldata proof
    )
        external
        view
        virtual
        returns (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData)
    {
        chainId = uint32(bytes4(proof[97:101]));
        _verifySequencerSignature(
            bytes32(proof[:32]),
            uint64(bytes8(proof[101:109])),
            uint8(proof[96]),
            bytes32(proof[32:64]),
            bytes32(proof[64:96])
        );

        uint256 eventEnd = uint16(bytes2(proof[126:128]));
        bytes memory rawEvent = proof[128:eventEnd];
        this.verifyMembership(
            bytes32(proof[:32]),
            ReceiptParser.eventRootKey(
                chainId,
                clientType,
                uint64(bytes8(proof[109:117])),
                uint32(bytes4(proof[117:121])),
                uint32(bytes4(proof[121:125]))
            ),
            keccak256(rawEvent),
            proof[eventEnd:]
        );

        (emittingContract, topics, unindexedData) = this.parseEvent(rawEvent, uint8(proof[125]));
    }

    /**
     * @notice Validates an event proof from Polymer's prove api for a Solana chain.
     * @notice These proofs should be generated using https://proof.devnet.polymer.zone
     * @notice Use `validateLogs` for non-Solana proofs.
     * @param proof The proof bytes containing:
     *     // SOLANA DECODING
     *     //          +---------------------------------------------------+
     *     // 0:32     |  state root                 (32 bytes)            |
     *     //          +---------------------------------------------------+
     *     // 32:97    |  signature                  (65 bytes)            |
     *     //          +---------------------------------------------------+
     *     // 97:101   |  source chain ID            (big endian, 4 bytes) |
     *     //          +---------------------------------------------------+
     *     // 101:109  |  peptide height             (big endian, 8 bytes) |
     *     //          +---------------------------------------------------+
     *     // 109:117  |  source chain block height  (big endian, 8 bytes) |
     *     //          +---------------------------------------------------+
     *     // 117      |  number of log messages     (1 byte)              |
     *     //          +---------------------------------------------------+
     *     // 118:150  |  txSignature (high)         (32 bytes)            |
     *     //          +---------------------------------------------------+
     *     // 150:182  |  txSignature (low)          (32 bytes)            |
     *     //          +---------------------------------------------------+
     *     // 182:214  |  programID                  (32 bytes)            |
     *     //          +---------------------------------------------------+
     *     // 214:216  |  (currLogMsgDataEnd,logMsg) (2 bytes, X bytes)    |
     *     //          +---------------------------------------------------+
     *     //          |  iavl proof                 (x bytes)             |
     *     //          +---------------------------------------------------+
     * @return chainId The ID of the chain the proof is from
     * @return programID The Solana program ID that emitted the logs
     * @return logMessages Array of log messages emitted by the program
     */
    function validateSolLogs(
        bytes calldata proof
    ) external view virtual returns (uint32 chainId, bytes32 programID, string[] memory logMessages) {
        chainId = uint32(bytes4(proof[97:101]));

        _verifySequencerSignature(
            bytes32(proof[:32]), // apphash
            uint64(bytes8(proof[101:109])), // peptide height
            uint8(proof[96]), // signature: v component
            bytes32(proof[32:64]), // signature: r component
            bytes32(proof[64:96]) // signature: s component
        );
        programID = bytes32(proof[182:214]);

        uint256 currLogMessageStart = 214;
        uint256 currentLogMessageEnd = 214; // Edge case for 0 log messages

        logMessages = new string[](uint8((proof[117]))); // number of log messages

        for (uint256 i = 0; i < logMessages.length; ++i) {
            currentLogMessageEnd = uint16(bytes2(proof[currLogMessageStart:currLogMessageStart + 2]));
            logMessages[i] = string(proof[currLogMessageStart + 2:currentLogMessageEnd]);
            currLogMessageStart = currentLogMessageEnd;
        }

        bytes memory rawEvent = abi.encodePacked(programID);
        for (uint256 i = 0; i < uint8((proof[117])); ++i) {
            rawEvent = abi.encodePacked(rawEvent, logMessages[i]);
        }

        this.verifyMembership(
            bytes32(proof[:32]), // apphash
            ReceiptParser.solanaEventRootKey(
                chainId,
                clientType,
                uint64(bytes8(proof[109:117])), // height
                bytes32(proof[118:150]), // tx signature high
                bytes32(proof[150:182]), // tx signature low
                programID
            ),
            keccak256(rawEvent),
            proof[currentLogMessageEnd:]
        );
    }

    /**
     * @notice Extracts log identifier information from a proof generated through Polymer's prove api.
     * This is useful for finding out which log was proven for a given proof bytes.
     * @param proof The complete cross-chain proof data containing log identifiers, returned from the prove api.
     * @return srcChain The source chain ID (extracted from bytes 97-101)
     * @return blockNumber The block number where the event was emitted (extracted from bytes 109-117)
     * @return receiptIndex The index of the receipt within the block (extracted from bytes 117-121)
     * @return logIndex The index of the log within the receipt (extracted from bytes 121-125)
     */
    function inspectLogIdentifier(
        bytes calldata proof
    ) external pure virtual returns (uint32 srcChain, uint64 blockNumber, uint32 receiptIndex, uint32 logIndex) {
        return (
            uint32(bytes4(proof[97:101])),
            uint64(bytes8(proof[109:117])),
            uint32(bytes4(proof[117:121])),
            uint32(bytes4(proof[121:125]))
        );
    }

    /**
     * @notice Extracts polymer chain state information from a proof generated through Polymer's prove api.
     * This is useful for finding out which polymer state was used to prove a log for a given proof bytes.
     * @param proof The complete cross-chain proof data containing Polymer state information
     * @return stateRoot The state root of the Polymer chain (extracted from the first 32 bytes)
     * @return height The height/block number of the Polymer chain (extracted from bytes 101-109)
     * @return signature The signature validating the state (extracted from bytes 32-97)
     */
    function inspectPolymerState(
        bytes calldata proof
    ) external pure virtual returns (bytes32 stateRoot, uint64 height, bytes calldata signature) {
        return (bytes32(proof[:32]), uint64(bytes8(proof[101:109])), proof[32:97]);
    }

    /**
     * @notice Verifies polymer state through an iavl proof. Useful for proving whether a given value exists in an iavl
     * tree of the given root
     * @param root The root of the iavl tree
     * @param key The key to verify in the iavl tree - in the case of this crossl2Prover, generated using
     * ReceiptParser.eventRootKey.
     * @param value The value to verify in the iavl tree - in the case of this crossl2Prover, the keccak256 hash of the
     * log data.
     * @notice this function will revert if the key, value, and root are not consistent with a valid iavl tree.
     * @notice The proof should be encoded in this following format:
     *     //
     * +----------------------------------------------------------------------------------------------------+
     *     // header:   |  number of paths (1B) | path-0 start (1B) |  prefix...  |  varint(len(key))
     * |
     *     //
     * +----------------------------------------------------------------------------------------------------+
     *     // path-0:   |  path-0 suffix start (1B)  |  path-0 suffix end (1B)  |  path-0 prefix... |  path-0 suffix...
     * |
     *     //
     * +----------------------------------------------------------------------------------------------------+
     *     // ...       |                                        ...
     * |
     *     //
     * +----------------------------------------------------------------------------------------------------+
     *     // path-n:   |  path-n suffix start (1B)  |  path-n suffix end (1B)  |  path-n prefix... |  path-n suffix...
     * |
     *     //
     * +----------------------------------------------------------------------------------------------------+
     */
    function verifyMembership(
        bytes32 root,
        bytes memory key,
        bytes32 value,
        bytes calldata proof
    ) public pure virtual {
        uint256 path0start = uint256(uint8(proof[1]));
        // Note: proof[2:path0start] includes both proof leaf prefix and the key length encoded as a protobuf varint
        bytes32 prehash = sha256(abi.encodePacked(proof[2:path0start], key, hex"20", sha256(abi.encodePacked(value))));
        uint256 offset = path0start;

        for (uint256 i = 0; i < uint256(uint8(proof[0])); ++i) {
            uint256 suffixstart = uint256(uint8(proof[offset]));
            uint256 suffixend = uint256(uint8(proof[offset + 1]));

            // add +2 to account for path header
            prehash = sha256(
                abi.encodePacked(
                    proof[offset + 2:offset + suffixstart], prehash, proof[offset + suffixstart:offset + suffixend]
                )
            );

            offset = offset + suffixend;
        }

        if (prehash != root) revert InvalidProofRoot();
    }

    /**
     * @notice Parses an event into its components: emitting contract address, indexed topics, and unindexed data
     * @dev Extracts components from a raw event byte array based on the number of topics
     * @param rawEvent The raw event data as bytes
     * @param numTopics Number of topics in the event (each topic is 32 bytes)
     * @return emittingContract The address of the contract that emitted the event
     * @return topics The indexed topics data
     * @return unindexedData The unindexed data of the event
     */
    function parseEvent(
        bytes calldata rawEvent,
        uint8 numTopics
    ) public pure virtual returns (address emittingContract, bytes memory topics, bytes memory unindexedData) {
        uint256 topicsEnd = 32 * numTopics + 20;
        return (address(bytes20(rawEvent[:20])), rawEvent[20:topicsEnd], rawEvent[topicsEnd:]);
    }

    /**
     * @notice Emit an event that can be proven on peptide
     * @dev This is useful for generating an event on chains with sparse events, e.g. for a health check to test that
     * polymer infra is working correctly
     * @dev Anyone can call this method!
     */
    function ping() external {
        emit Ping();
    }
}
