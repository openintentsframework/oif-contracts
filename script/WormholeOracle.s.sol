// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Script } from "forge-std/Script.sol";

import { WormholeOracle } from "../src/integrations/oracles/wormhole/WormholeOracle.sol";

contract DeployWormholeOracle is Script {
    function deploy(
        address owner,
        address wormholeOracle
    ) external {
        vm.broadcast();
        address(new WormholeOracle{ salt: bytes32(0) }(owner, wormholeOracle));
    }

    uint256[2][] wormholeTestnetMaps;
    uint256[2][] wormholeMaps;

    constructor() {
        wormholeTestnetMaps = new uint256[2][](2);
        wormholeTestnetMaps[0] = [11155111, 10002];
        wormholeTestnetMaps[1] = [84532, 10004];

        wormholeMaps = new uint256[2][](3);
        wormholeMaps[0] = [8453, 30];
        wormholeMaps[1] = [42161, 23];
        wormholeMaps[2] = [10, 24];
    }

    function setTestnetChainMap(
        address wormholeOracle
    ) external {
        setMap(WormholeOracle(wormholeOracle), wormholeTestnetMaps);
    }

    function setChainMap(
        address wormholeOracle
    ) external {
        setMap(WormholeOracle(wormholeOracle), wormholeMaps);
    }

    function setMap(
        WormholeOracle wormholeOracle,
        uint256[2][] memory map
    ) internal {
        // Check if each chain has already been set. Otherwise set it.
        uint256 numMaps = map.length;
        for (uint256 i; i < numMaps; ++i) {
            uint256[2] memory selectMap = map[i];
            uint256 chainId = selectMap[0];
            if (wormholeOracle.reverseChainIdMap(chainId) != 0) continue;
            uint16 messagingProtocolChainIdentifier = uint16(selectMap[1]);
            if (wormholeOracle.chainIdMap(uint256(messagingProtocolChainIdentifier)) != 0) continue;

            vm.broadcast();
            WormholeOracle(wormholeOracle).setChainMap(uint256(messagingProtocolChainIdentifier), chainId);
        }
    }
}
