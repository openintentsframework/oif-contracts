// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Script } from "forge-std/Script.sol";

import { OutputSettlerOrderTypes } from "../src/output/OutputSettlerOrderTypes.sol";

contract DeployOutputSettlerCoin is Script {
    function deploy() external {
        vm.broadcast();
        address(new OutputSettlerOrderTypes{ salt: bytes32(0) }());
    }
}
