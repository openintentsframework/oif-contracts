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

import { ECDSA } from "openzeppelin/utils/cryptography/ECDSA.sol";

/**
 * @title SequencerSignatureVerifierV2
 * @notice Verifies ECDSA signatures from a sequencer for client updates. Is used by the SequencerSoloClient to verify
 * signatures on client updates.
 * @author Polymer Labs
 */
contract SequencerSignatureVerifierV2 {
    address public immutable SEQUENCER; // The trusted sequencer address that polymer p2p signer holds the private key
        // to
    bytes32 public immutable CHAIN_ID; // Chain ID of the L2 chain for which the sequencer signs over

    error InvalidSequencerSignature();

    constructor(
        address sequencer_,
        bytes32 chainId_
    ) {
        SEQUENCER = sequencer_;
        CHAIN_ID = chainId_;
    }

    /**
     * @notice Verify peptide sequencer signature over a given apphash
     */
    function _verifySequencerSignature(
        bytes32 appHash,
        uint64 peptideHeight,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        if (
            ECDSA.recover(
                    keccak256(bytes.concat(bytes32(0), CHAIN_ID, keccak256(abi.encodePacked(appHash, peptideHeight)))),
                    bytes(abi.encodePacked(r, s, v))
                ) != SEQUENCER
        ) revert InvalidSequencerSignature();
    }
}
