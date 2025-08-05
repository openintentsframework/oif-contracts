// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Script } from "forge-std/Script.sol";

import { BaseOutputSettler } from "../src/output/BaseOutputSettler.sol";

contract DeployOutputSettlerCoin is Script {
    function deploy() external {
        vm.broadcast();
        address(new BaseOutputSettler{ salt: bytes32(0) }());
    }
}
