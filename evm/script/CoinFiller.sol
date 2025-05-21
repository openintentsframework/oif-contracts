// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Script } from "forge-std/Script.sol";
import { CoinFiller } from "src/fillers/coin/CoinFiller.sol";

contract DeployCoinFiller is Script {
    function deploy() external {
        vm.broadcast();
        address(new CoinFiller{ salt: bytes32(0) }());
    }
}
