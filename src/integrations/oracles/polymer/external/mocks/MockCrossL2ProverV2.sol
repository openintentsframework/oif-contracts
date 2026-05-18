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

import { CrossL2ProverV2 } from "../core/prove_api/CrossL2ProverV2.sol";

contract MockCrossL2ProverV2 is CrossL2ProverV2 {
    // Event for proof generation
    event ProofGenerated(bytes proof);

    constructor(
        string memory clientType_,
        address sequencer_,
        bytes32 chainId_
    ) CrossL2ProverV2(clientType_, sequencer_, chainId_) { }

    /**
     * @dev Generates a mock proof and emits it for local testing.
     * @param chainId_ Source chain ID.
     * @param emitter Address of the emitting contract.
     * @param topics Array of topic hashes (32 bytes each).
     * @param data Unindexed event data.
     * @return Mock proof bytes.
     */
    function generateAndEmitProof(
        uint32 chainId_,
        address emitter,
        bytes32[] memory topics,
        bytes memory data
    ) external returns (bytes memory) {
        require(topics.length > 0, "At least one topic (event signature) required");

        bytes memory proof = generateMockProof(chainId_, uint8(topics.length), emitter, topics, data);

        emit ProofGenerated(proof);
        return proof;
    }

    /**
     * @dev Generates a mock proof and sends it to a validator contract.
     * @param chainId_ Source chain ID.
     * @param emitter Address of the emitting contract.
     * @param topics Array of topic hashes (32 bytes each).
     * @param data Unindexed event data.
     * @param validatorContract Address of the contract to validate the proof.
     * @return Mock proof bytes.
     */
    function generateAndSendProof(
        uint32 chainId_,
        address emitter,
        bytes32[] memory topics,
        bytes memory data,
        address validatorContract
    ) external returns (bytes memory) {
        require(topics.length > 0, "At least one topic (event signature) required");
        require(validatorContract != address(0), "Invalid validator contract address");

        bytes memory proof = generateMockProof(chainId_, uint8(topics.length), emitter, topics, data);

        // Call the validator contract's validateEvent function
        (bool success,) = validatorContract.call(abi.encodeWithSignature("validateEvent(bytes)", proof));
        require(success, "Validation call failed");

        return proof;
    }

    /**
     * @dev Modified validateEvent for testing. Skips signature and membership verification
     * to focus on proof structure and event parsing.
     */
    function validateEvent(
        bytes calldata proof
    )
        external
        view
        override
        returns (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData)
    {
        // Extract chainId from proof[97:101]
        chainId = uint32(bytes4(proof[97:101]));

        // Skip sequencer signature verification (normally done with _verifySequencerSignature)
        // In production, this ensures the proof is signed by the sequencer, but for testing,
        // we assume a valid signature.

        // Calculate event end from proof[121:123]
        uint256 eventEnd = uint256(uint16(bytes2(proof[121:123])));
        require(eventEnd <= proof.length, "Event end exceeds proof length");
        bytes memory rawEvent = proof[123:eventEnd];

        // Skip IAVL proof verification (normally done with verifyMembership)
        // In production, this checks the event's inclusion in the state root, but for testing,
        // we assume membership is valid.

        // Parse the event data
        (emittingContract, topics, unindexedData) = this.parseEvent(rawEvent, uint8(proof[120]));
    }

    /**
     * @dev Helper function to generate a mock proof for testing.
     * @param chainId_ Source chain ID.
     * @param numTopics Number of topics in the event.
     * @param emitter Address of the emitting contract.
     * @param topics_ Array of topic hashes (32 bytes each).
     * @param unindexedData_ Unindexed event data.
     * @return Mock proof bytes.
     */
    function generateMockProof(
        uint32 chainId_,
        uint8 numTopics,
        address emitter,
        bytes32[] memory topics_,
        bytes memory unindexedData_
    ) public pure returns (bytes memory) {
        require(topics_.length == numTopics, "Topics length mismatch");

        // Calculate lengths
        uint256 topicsLength = numTopics * 32;
        uint256 eventLength = 20 + topicsLength + unindexedData_.length; // emitter + topics + data
        uint256 eventEnd = 123 + eventLength; // Offset after fixed fields

        // Assemble proof
        bytes memory proof = new bytes(eventEnd + 32); // Add 32 bytes for dummy iavlProof

        // Leave fixed fields with dummy or specified values
        // - stateRoot (32 bytes): dummy
        // - signature (65 bytes): dummy
        // Values are 0 so we don't have to set them here

        // populate given chainId (4 bytes)
        bytes4 chainIdBytes = bytes4(chainId_);
        for (uint256 i = 0; i < 4; i++) {
            proof[97 + i] = chainIdBytes[i];
        }
        // peptideHeight (proof[101:109]) dummy value of 100
        proof[108] = bytes1(uint8(100));

        // blockHeight (proof[109:117]) dummy value of 200
        proof[116] = bytes1(uint8(200));

        // - receiptIndex proof[117-118] dummy avlue of 1
        proof[118] = bytes1(uint8(1));
        // eventIndex proof[119]: dummy  value of 0
        proof[119] = bytes1(0);
        // numTopics proof[120]  dummy value of num topics
        proof[120] = bytes1(numTopics);

        // eventDataEnd (2 bytes)
        bytes2 eventEndBytes = bytes2(uint16(eventEnd));
        proof[121] = eventEndBytes[0];
        proof[122] = eventEndBytes[1];

        // Event data: emitter (20 bytes) + topics + unindexedData
        bytes20 emitterBytes = bytes20(emitter);
        for (uint256 i = 0; i < 20; i++) {
            proof[123 + i] = emitterBytes[i];
        }
        for (uint256 i = 0; i < numTopics; i++) {
            bytes32 topic = topics_[i];
            for (uint256 j = 0; j < 32; j++) {
                proof[143 + i * 32 + j] = topic[j];
            }
        }
        for (uint256 i = 0; i < unindexedData_.length; i++) {
            proof[143 + topicsLength + i] = unindexedData_[i];
        }

        // iavlProof (dummy, 32 bytes)
        for (uint256 i = eventEnd; i < proof.length; i++) {
            proof[i] = bytes1(0);
        }

        return proof;
    }
}
