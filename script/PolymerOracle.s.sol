// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Script } from "forge-std/Script.sol";

import { PolymerOracleMapped } from "../src/integrations/oracles/polymer/PolymerOracleMapped.sol";

contract DeployPolymerOracle is Script {
    function deploy(
        address owner,
        address crossL2Prover
    ) external {
        vm.broadcast();
        address(new PolymerOracleMapped{ salt: bytes32(0) }(owner, crossL2Prover));
    }

    uint256[2][] polymerMaps;

    constructor() {
        polymerMaps = new uint256[2][](2);
        polymerMaps[0] = [84532, 84532];
        polymerMaps[1] = [2, 11];
    }

    function setChainMap(
        address polymerOracle
    ) external {
        setMap(PolymerOracleMapped(polymerOracle), polymerMaps);
    }

    function setMap(
        PolymerOracleMapped polymerOracle,
        uint256[2][] memory map
    ) internal {
        // Check if each chain has already been set. Otherwise set it.
        uint256 numMaps = map.length;
        for (uint256 i; i < numMaps; ++i) {
            uint256[2] memory selectMap = map[i];
            uint256 protocolChainIdentifier = selectMap[0];
            if (polymerOracle.chainIdMap(protocolChainIdentifier) != 0) continue;
            uint256 chainId = selectMap[1];
            if (polymerOracle.reverseChainIdMap(chainId) != 0) continue;

            vm.broadcast();
            polymerOracle.setChainMap(protocolChainIdentifier, chainId);
        }
    }
}

