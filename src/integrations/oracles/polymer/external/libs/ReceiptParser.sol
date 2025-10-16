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

pragma solidity ^0.8.0;

import { RLPReader } from "../optimism/rlp/RLPReader.sol";
import { Bytes } from "openzeppelin/utils/Bytes.sol";
import { Strings } from "openzeppelin/utils/Strings.sol";

/**
 * A library for helpers for proving peptide state
 */
library ReceiptParser {
    error invalidAddressBytes();

    function bytesToAddr(
        bytes memory a
    ) public pure returns (address addr) {
        if (a.length != 20) revert invalidAddressBytes();
        assembly {
            addr := mload(add(a, 20))
        }
    }

    function parseLog(
        uint256 logIndex,
        bytes memory receiptRLP
    ) internal pure returns (address emittingContract, bytes[] memory topics, bytes memory unindexedData) {
        // The first byte is a RLP encoded receipt type so slice it off.
        uint8 typeByte;
        assembly {
            typeByte := byte(0, mload(add(receiptRLP, 32)))
        }
        if (typeByte < 0x80) {
            // Typed receipt: strip the type byte
            receiptRLP = Bytes.slice(receiptRLP, 1, receiptRLP.length - 1);
        }

        RLPReader.RLPItem[] memory receipt = RLPReader.readList(receiptRLP);
        /*
            // RLP encoded receipt has the following structure. Logs are the 4th RLP list item.
            type ReceiptRLP struct {
                    PostStateOrStatus []byte
                   CumulativeGasUsed uint64
                    Bloom             Bloom
                    Logs              []*Log
            }
        */

        // Each log itself is an rlp encoded datatype of 3 properties:
        // type Log struct {
        //         senderAddress bytes // contract address where this log was emitted from
        //         topics bytes        // Array of indexed topics. The first element is the 32-byte selector of the
        // event (can use TransmitToHouston.selector), and the following  elements in this array are the abi encoded
        // arguments individually
        //         topics data         // abi encoded raw bytes of unindexed data
        // }
        RLPReader.RLPItem[] memory log = RLPReader.readList(RLPReader.readList(receipt[3])[logIndex]);

        emittingContract = bytesToAddr(RLPReader.readBytes(log[0]));

        RLPReader.RLPItem[] memory encodedTopics = RLPReader.readList(log[1]);
        unindexedData = (RLPReader.readBytes(log[2])); // This is the raw unindexed data. in this case it's
            // just an abi encoded uint64

        topics = new bytes[](encodedTopics.length);
        for (uint256 i = 0; i < encodedTopics.length; i++) {
            topics[i] = RLPReader.readBytes(encodedTopics[i]);
        }
    }

    function receiptRootKey(
        string memory chainId,
        string memory clientType,
        uint256 height
    ) internal pure returns (bytes memory proofKey) {
        proofKey = abi.encodePacked(
            "chain/", chainId, "/storedReceipts/", clientType, "/receiptRoot/", Strings.toString(height)
        );
    }

    function eventRootKey(
        uint32 chainId,
        string memory clientType,
        uint256 height,
        uint32 receiptIndex,
        uint32 logIndex
    ) internal pure returns (bytes memory proofKey) {
        return abi.encodePacked(
            "chain/",
            Strings.toString(uint256(chainId)),
            "/storedLogs/",
            clientType,
            "/",
            Strings.toString(height),
            "/",
            Strings.toString(receiptIndex),
            "/",
            Strings.toString(logIndex)
        );
    }

    // computes the root key for a solana event. The transaction signature (64 bytes) is split in two bytes32
    // high and low variables to make the hex conversion more gas efficient
    function solanaEventRootKey(
        uint32 chainId,
        string memory clientType,
        uint64 height,
        bytes32 txSignatureHigh,
        bytes32 txSignatureLow,
        bytes32 programID
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            "chain/",
            Strings.toString(uint256(chainId)),
            "/storedLogs/",
            clientType,
            "/",
            height,
            "/",
            txSignatureHigh,
            txSignatureLow,
            "/",
            programID
        );
    }
}
