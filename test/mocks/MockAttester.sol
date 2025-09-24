// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IAttester } from "../../src/interfaces/IAttester.sol";

contract MockAttester is IAttester {
    mapping(bytes => bool) _hasAttest;

    function hasAttested(
        bytes[] calldata payloads
    ) external view returns (bool val) {
        val = true;
        for (uint256 i; i < payloads.length; ++i) {
            bool next = _hasAttest[payloads[i]];
            assembly ("memory-safe") {
                val := and(val, next)
            }
        }
    }

    function setAttested(bool status, bytes calldata payload) external {
        _hasAttest[payload] = status;
    }
}
