// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Script } from "forge-std/Script.sol";

import { OutputSettlerCoin } from "../src/output/coin/OutputSettlerCoin.sol";

contract DeployOutputSettlerCoin is Script {
    function deploy() external {
        vm.broadcast();
        address(new OutputSettlerCoin{ salt: bytes32(0) }());
    }
}
