// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { TheCompact } from "the-compact/src/TheCompact.sol";
import { IdLib } from "the-compact/src/lib/IdLib.sol";
import { AlwaysOKAllocator } from "the-compact/src/test/AlwaysOKAllocator.sol";

import { CoinFiller } from "../../src/fillers/coin/CoinFiller.sol";
import { WormholeOracle } from "../../src/oracles/wormhole/WormholeOracle.sol";
import { AlwaysYesOracle } from "../../test/mocks/AlwaysYesOracle.sol";
import { SettlerCompact } from "../../src/settlers/compact/SettlerCompact.sol";


import { multichain } from "./multichain.s.sol";

contract deploy is multichain {
    error NotExpectedAddress(string name, address expected, address actual);

    address public constant COMPACT = address(0x70EEFf73E540C8F68477510F096c0d903D31594a);
    uint256 private constant _ALLOCATOR_BY_ALLOCATOR_ID_SLOT_SEED = 0x000044036fc77deaed2300000000000000000000000;

    function run(
        string[] calldata chains
    ) public returns (SettlerCompact settler) {
        address expectedSettlerAddress = getExpectedCreate2Address(
            0, // salt
            type(SettlerCompact).creationCode,
            abi.encode(COMPACT)
        );
        return run(chains, expectedSettlerAddress);
    }

    function run(
        string[] calldata chains,
        address expectedSettlerAddress
    ) public iter_chains(chains) broadcast returns (SettlerCompact settler) {
        deployCompact();
        settler = deploySettler(expectedSettlerAddress);

        deployCoinFiller();
        deployAlwaysOkAllocaor();
        deployAlwaysYesOracle();
    }

    function deploySettler(
        address expectedSettlerAddress
    ) internal returns (SettlerCompact settler) {
        bool isSettlerDeployed = address(expectedSettlerAddress).code.length != 0;

        if (!isSettlerDeployed) {
            settler = new SettlerCompact{ salt: 0 }(COMPACT);

            if (expectedSettlerAddress != address(settler)) {
                revert NotExpectedAddress("settler", expectedSettlerAddress, address(settler));
            }
            return settler;
        }
        return SettlerCompact(expectedSettlerAddress);
    }

    function deployCompact() internal {
        bool isCompactDeployed = COMPACT.code.length != 0;

        if (!isCompactDeployed) {
            address compact = address(new TheCompact{ salt: 0 }());

            if (COMPACT != compact) revert NotExpectedAddress("compact", COMPACT, compact);
        }
    }

    function deployCoinFiller() internal returns (CoinFiller filler) {
        address expectedAddress = getExpectedCreate2Address(
            0, // salt
            type(CoinFiller).creationCode,
            hex""
        );
        bool isFillerDeployed = address(expectedAddress).code.length != 0;

        if (!isFillerDeployed) return filler = new CoinFiller{ salt: 0 }();
        return CoinFiller(expectedAddress);
    }

    function deployAlwaysOkAllocaor() internal returns (AlwaysOKAllocator allocator, uint96 allocatorId) {
        address expectedAddress = getExpectedCreate2Address(
            0, // salt
            type(AlwaysOKAllocator).creationCode,
            hex""
        );
        bool isAllocatorDeployed = address(expectedAddress).code.length != 0;

        if (!isAllocatorDeployed) allocator = new AlwaysOKAllocator{ salt: 0 }();
        else allocator = AlwaysOKAllocator(expectedAddress);

        allocatorId = IdLib.usingAllocatorId(address(allocator));

        bytes32 storageSlotKey;
        assembly {
            storageSlotKey := or(_ALLOCATOR_BY_ALLOCATOR_ID_SLOT_SEED, allocatorId)
        }

        bytes32 storageSlotValue = vm.load(COMPACT, storageSlotKey);
        if (storageSlotValue == bytes32(0)) {
            uint96 registeredAllocatorId = TheCompact(COMPACT).__registerAllocator(address(allocator), "");
            assert(registeredAllocatorId == allocatorId);
        }
    }

    function deployAlwaysYesOracle() internal returns (AlwaysYesOracle oracle) {
        address expectedAddress = getExpectedCreate2Address(
            0, // salt
            type(AlwaysYesOracle).creationCode,
            hex""
        );
        bool isOracleDeployed = address(expectedAddress).code.length != 0;

        if (!isOracleDeployed) return oracle = new AlwaysYesOracle{ salt: 0 }();
        return AlwaysYesOracle(expectedAddress);
    }
}
