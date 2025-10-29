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

import { ISignatureVerifier } from "../../interfaces/ISignatureVerifier.sol";
import { ECDSA } from "openzeppelin/utils/cryptography/ECDSA.sol";

/**
 * @title SequencerSignatureVerifier
 * @notice Verifies ECDSA signatures from a sequencer for client updates. Is used by the SequencerSoloClient to verify
 * signatures on client updates.
 * @author Polymer Labs
 */
contract SequencerSignatureVerifier is ISignatureVerifier {
    address public immutable SEQUENCER; // The trusted sequencer address that polymer p2p signer holds the private key
        // to
    bytes32 public immutable CHAIN_ID; // Chain ID of the L2 chain for which the sequencer signs over

    constructor(
        address sequencer_,
        bytes32 chainId_
    ) {
        SEQUENCER = sequencer_;
        CHAIN_ID = chainId_;
    }

    /**
     * @notice Verifies that the sequencer signature is valid for a given l1 origin. This is used by the
     * SequencerSoloClient update client method.
     * @param l2BlockNumber The block number of the L2 block that the state update is for
     * @param appHash The app hash of the state update to be saved in the parent soloClient contract
     * @param l1BlockHash The hash of the L1 origin that the peptide height corresponds to
     * @param signature The sequencer's ECDSA over the state update
     */
    function verifyStateUpdate(
        uint256 l2BlockNumber,
        bytes32 appHash,
        bytes32 l1BlockHash,
        bytes calldata signature
    ) external view {
        _verifySequencerSignature(l2BlockNumber, appHash, l1BlockHash, signature);
    }

    /**
     * @notice Verify the ECDSA signature of the sequencer over the given l2BLockNumber, peptideAppHash, and origin
     * l1BlockHash
     */
    function _verifySequencerSignature(
        uint256 l2BlockNumber,
        bytes32 appHash,
        bytes32 l1BlockHash,
        bytes calldata signature
    ) internal view {
        // Signature will be the keccak256 hash of a + b, where:
        // a =  (empty bytes 32 corresponding to the Domain) + ( peptide chain Id )
        // b = keccak((l2 block number ) + ( l2 apphash) + ( l1 origin hash))
        if (
            ECDSA.recover(
                    keccak256(
                        bytes.concat(
                            bytes32(0), CHAIN_ID, keccak256(bytes.concat(bytes32(l2BlockNumber), appHash, l1BlockHash))
                        )
                    ),
                    signature
                ) != SEQUENCER
        ) revert InvalidSequencerSignature();
    }
}
