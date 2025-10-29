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

import { ICrossL2ProverV2 } from "../../interfaces/ICrossL2ProverV2.sol";

/**
 * @title CrossL2Executor
 * @notice Contract that executes validateEvent calls on a CrossL2ProverV2 contract with topic validation
 * @dev This contract provides a non-view function for E2E testing by calling validateEvent and comparing topics
 */
contract CrossL2Executor {
    ICrossL2ProverV2 public immutable prover;

    event ValidationSuccess(uint32 chainId, address emittingContract, bytes topics, bytes unindexedData);
    event Ping();

    error TopicsDoNotMatch(bytes expected, bytes actual);

    constructor(
        address _prover
    ) {
        prover = ICrossL2ProverV2(_prover);
    }

    /**
     * @notice Execute validateEvent with topic comparison
     * @param proof The proof bytes to validate
     * @param expectedTopics The expected topics to compare against
     * @dev Calls validateEvent on the prover contract and compares returned topics with expectedTopics
     *      If topics match, emits ValidationSuccess event. If not, reverts with TopicsDoNotMatch.
     */
    function executeValidateEvent(
        bytes calldata proof,
        bytes calldata expectedTopics
    ) external {
        (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData) =
            prover.validateEvent(proof);

        // Compare topics
        if (keccak256(topics) != keccak256(expectedTopics)) revert TopicsDoNotMatch(expectedTopics, topics);

        emit ValidationSuccess(chainId, emittingContract, topics, unindexedData);
    }

    /**
     * @notice Simple ping function to emit success event
     * @dev Can be used for basic E2E testing without topic comparison
     */
    function ping() external {
        emit Ping();
    }
}
