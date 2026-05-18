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

import { L1Configuration, L2Configuration } from "../libs/RegistryTypes.sol";

/**
 * @title IRegistry
 * @author Polymer Labs
 * @notice A contract for implementing an L2 settlement location registry on the L1
 */
interface IRegistry {
    function updateL2ChainConfiguration(
        uint256 chainID,
        L2Configuration calldata config
    ) external;

    function updateL1ChainConfiguration(
        uint256 chainID,
        L1Configuration calldata config
    ) external;

    function grantChainID(
        address _grantee,
        uint256 _chainID
    ) external;

    function grantChainIDIrrevocable(
        address _grantee,
        uint256 _chainID
    ) external;

    function grantChainIDRange(
        address _grantee,
        uint256 _startChainID,
        uint256 _stopChainID
    ) external;

    function grantChainIDRangeIrrevocable(
        address _grantee,
        uint256 _startChainID,
        uint256 _stopChainID
    ) external;

    function isRevocableGrantee(
        address _grantee,
        uint256 _chainID
    ) external view returns (bool);

    function isIrrevocableGrantee(
        address _grantee,
        uint256 _chainID
    ) external view returns (bool);
}
