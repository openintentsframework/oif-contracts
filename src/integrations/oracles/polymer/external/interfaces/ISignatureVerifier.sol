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

/**
 * @title ISignatureVerifier
 * @author Polymer Labs
 * @notice An interface that abstracts away proof verification logic for light clients
 */
interface ISignatureVerifier {
    error InvalidSequencerSignature();

    function verifyStateUpdate(
        uint256 l2BlockNumber,
        bytes32 appHash,
        bytes32 l1BlockHash,
        bytes calldata signature
    ) external;

    function SEQUENCER() external view returns (address);
    function CHAIN_ID() external view returns (bytes32);
}
