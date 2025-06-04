// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Script, console } from "forge-std/Script.sol";

/**
 * @notice Easily deploy contracts across multiple chains.
 */
contract multichain is Script {
    string public chain;
    string private constant RPC_URL_PREFIX = "RPC_URL_";

    function getChainRpcEnvKey(
        string memory chain_
    ) private pure returns (string memory) {
        return string(abi.encodePacked(RPC_URL_PREFIX, vm.toUppercase(chain_)));
    }

    function getSender() internal broadcast returns (address) {
        address[] memory availableWallets = vm.getWallets();
        return availableWallets[0];
    }

    function getChain() public view returns (string memory) {
        return chain;
    }

    function selectFork(
        string memory chain_
    ) internal {
        vm.createSelectFork(vm.envString(getChainRpcEnvKey(chain_)));
    }

    modifier iter_chains(
        string[] memory chains
    ) {
        for (uint256 chainIndex = 0; chainIndex < chains.length; ++chainIndex) {
            chain = chains[chainIndex];
            selectFork(chain);

            _;
        }
    }

    modifier broadcast() {
        vm.startBroadcast();

        _;

        vm.stopBroadcast();
    }

    // --- Deployment helpers for ---//
    function getExpectedCreate2Address(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory initArgs
    ) public pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(CREATE2_FACTORY),
                            salt, // salt
                            keccak256(abi.encodePacked(creationCode, initArgs))
                        )
                    )
                )
            )
        );
    }
}
