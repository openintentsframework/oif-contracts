// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Script } from "forge-std/Script.sol";

import { OutputSettlerResolver } from "../src/output/orders/OutputSettlerResolver.sol";

contract DeployOutputSettlerCoin is Script {
    function deploy() external {
        vm.broadcast();
        address(new OutputSettlerResolver{ salt: bytes32(0) }());
    }
}
