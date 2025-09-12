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

import { ProveL1ScalarArgs, ProveScalarArgs, UpdateL2ConfigArgs } from "../libs/RegistryTypes.sol";

/**
 * @title INativeProver
 * @author Polymer Labs
 * @notice A contract for implementing a L2<->L1<->L2 cross-L2 prover
 */
interface INativeProver {
    function proveL2Native(
        UpdateL2ConfigArgs calldata _updateArgs,
        ProveScalarArgs calldata _proveArgs,
        bytes calldata _rlpEncodedL1Header,
        bytes memory _rlpEncodedL2Header,
        bytes calldata _settledStateProof,
        bytes[] calldata _l2StorageProof,
        bytes calldata _rlpEncodedContractAccount,
        bytes[] calldata _l2AccountProof
    )
        external
        view
        returns (
            uint256 chainId,
            address storingContract,
            uint256 srcBlockNumber,
            bytes32 storageSlot,
            bytes32 storageValue
        );

    function proveL1Native(
        ProveL1ScalarArgs calldata _proveArgs,
        bytes calldata _rlpEncodedL1Header,
        bytes[] calldata _l1StorageProof,
        bytes calldata _rlpEncodedContractAccount,
        bytes[] calldata _l1AccountProof
    )
        external
        view
        returns (
            uint256 chainId,
            address storingContract,
            uint256 srcBlockNumber,
            bytes32 storageSlot,
            bytes32 storageValue
        );
}
