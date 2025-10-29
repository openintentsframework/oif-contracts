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

enum Type {
    Nitro,
    OPStackBedrock,
    OPStackCannon
}

struct L2Configuration {
    address prover;
    address[] addresses;
    uint256[] storageSlots;
    uint256 versionNumber;
    uint256 finalityDelaySeconds;
    Type l2Type;
}

struct L1Configuration {
    address blockHashOracle;
    address settlementRegistry;
    uint256 settlementRegistryL2ConfigMappingSlot;
    uint256 settlementRegistryL1ConfigMappingSlot;
}

/**
 * @notice Struct to hold scalar args to prove()
 * @dev To avoid stack-too-deep
 * @param _chainID chain ID of the L2 configuration being proven
 * @param _contractAddr contract address on the L2 storing the value
 * @param _storageSlot storage slot being proven
 * @param _storageValue the storage value being proven
 * @param _l2WorldStateRoot L2 world state root
 *
 */
struct ProveScalarArgs {
    uint256 chainID;
    address contractAddr;
    bytes32 storageSlot;
    bytes32 storageValue;
    bytes32 l2WorldStateRoot;
}

struct ProveL1ScalarArgs {
    address contractAddr;
    bytes32 storageSlot;
    bytes32 storageValue;
    bytes32 l1WorldStateRoot;
}

struct UpdateL2ConfigArgs {
    L2Configuration config;
    bytes[] l1StorageProof;
    bytes rlpEncodedRegistryAccountData;
    bytes[] l1RegistryProof;
}
