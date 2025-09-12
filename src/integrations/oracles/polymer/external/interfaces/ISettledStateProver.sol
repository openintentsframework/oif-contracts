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

import { L2Configuration } from "../libs/RegistryTypes.sol";

/**
 * @title ISettledStateProver
 * @author Polymer Labs
 * @notice A contract that verifies a L2 state settled into a given L1 state root
 */
interface ISettledStateProver {
    function proveSettledState(
        L2Configuration memory _chainConfig,
        bytes32 _l2WorldStateRoot,
        bytes memory _rlpEncodedBlockData,
        bytes32 _l1WorldStateRoot,
        bytes calldata _proof
    ) external view returns (bool);
}
