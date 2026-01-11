// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { OutputSettlerSimple } from "../src/output/simple/OutputSettlerSimple.sol";

import { multichain } from "./multichain.s.sol";

import { InputSettlerCompact } from "../src/input/compact/InputSettlerCompact.sol";
import { InputSettlerEscrow } from "../src/input/escrow/InputSettlerEscrow.sol";

import { console } from "forge-std/console.sol";

contract deploy is multichain {
    error NotExpectedAddress(string name, address expected, address actual);

    address public constant COMPACT = address(0x0000000038568013727833b4Ad37B53bb1b6f09d);

    bytes32 inputSettlerCompactSalt = 0x0000000000000000000000000000000000000000821744ee10d391b2dc1a0040;
    bytes32 inputSettlerEscrowSalt = 0x00000000000000000000000000000000000000001b57ce058d1b5f08be060020;
    bytes32 outputSettlerSalt = 0x00000000000000000000000000000000000000002314fd828687df37e06200b0;

    function run(
        string[] calldata chains
    )
        public
        iter_chains(chains)
        broadcast
        returns (InputSettlerCompact inputSettlerCompact, InputSettlerEscrow inputSettlerEscrow)
    {
        inputSettlerCompact = deployInputSettlerCompact();
        inputSettlerEscrow = deployInputSettlerEscrow();

        deployOutputSettlerSimple();
    }

    function deployInputSettlerCompact() internal returns (InputSettlerCompact settler) {
        address expectedInputSettlerCompactAddress = getExpectedCreate2Address(
            inputSettlerCompactSalt, type(InputSettlerCompact).creationCode, abi.encode(COMPACT)
        );
        bool isSettlerDeployed = address(expectedInputSettlerCompactAddress).code.length != 0;

        if (!isSettlerDeployed) {
            settler = new InputSettlerCompact{ salt: inputSettlerCompactSalt }(COMPACT);

            if (expectedInputSettlerCompactAddress != address(settler)) {
                revert NotExpectedAddress("settler", expectedInputSettlerCompactAddress, address(settler));
            }
            return settler;
        }
        return InputSettlerCompact(expectedInputSettlerCompactAddress);
    }

    function deployInputSettlerEscrow() internal returns (InputSettlerEscrow settler) {
        address expectedInputSettlerEscrowAddress =
            getExpectedCreate2Address(inputSettlerEscrowSalt, type(InputSettlerEscrow).creationCode, hex"");
        bool isSettlerDeployed = address(expectedInputSettlerEscrowAddress).code.length != 0;

        if (!isSettlerDeployed) {
            settler = new InputSettlerEscrow{ salt: inputSettlerEscrowSalt }();

            if (expectedInputSettlerEscrowAddress != address(settler)) {
                revert NotExpectedAddress("settler", expectedInputSettlerEscrowAddress, address(settler));
            }
            return settler;
        }
        return InputSettlerEscrow(expectedInputSettlerEscrowAddress);
    }

    function deployOutputSettlerSimple() internal returns (OutputSettlerSimple filler) {
        address expectedAddress = getExpectedCreate2Address(
            outputSettlerSalt, // salt
            type(OutputSettlerSimple).creationCode,
            hex""
        );
        bool isFillerDeployed = address(expectedAddress).code.length != 0;

        if (!isFillerDeployed) return filler = new OutputSettlerSimple{ salt: outputSettlerSalt }();
        return OutputSettlerSimple(expectedAddress);
    }
}
