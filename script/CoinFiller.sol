// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Script } from "forge-std/Script.sol";

import { OutputSettlerSimple } from "../src/output/simple/OutputSettlerSimple.sol";

contract DeployOutputSettlerSimple is Script {
    function deploy() external {
        vm.broadcast();
        address(new OutputSettlerSimple{ salt: bytes32(0) }());
    }
}
