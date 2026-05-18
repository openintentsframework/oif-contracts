// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IInputOracle } from "../../src/interfaces/IInputOracle.sol";

contract AlwaysYesOracle is IInputOracle {
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
