// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ILocalOracle } from "../../src/interfaces/ILocalOracle.sol";

contract AlwaysYesOracle is ILocalOracle {
    function isProven(
        uint256, /* remoteChainId */
        bytes32, /* remoteOracle */
        bytes32, /* application */
        bytes32 /* dataHash */
    ) external pure returns (bool) {
        return true;
    }

    function efficientRequireProven(
        bytes calldata /* proofSeries */
    ) external pure { }
}
