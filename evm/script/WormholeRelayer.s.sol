// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Script } from "forge-std/Script.sol";

import { WormholeOracle } from "../src/oracles/wormhole/WormholeOracle.sol";

contract WormholeRelayer is Script {
    function relay(address receiveOracle, bytes calldata vaa) external {
        vm.broadcast();
        WormholeOracle(receiveOracle).receiveMessage(vaa);
    }
}
