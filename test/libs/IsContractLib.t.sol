// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { CoinFiller } from "../../src/fillers/coin/CoinFiller.sol";
import { IsContractLib } from "../../src/libs/IsContractLib.sol";
import { SettlerCompact } from "../../src/settlers/compact/SettlerCompact.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

/// @dev harness is used to place the revert at a lower call depth than our current.
contract IsContractLibHarness {
    function checkCodeSize(
        address addr
    ) external view {
        IsContractLib.checkCodeSize(addr);
    }
}

contract IsContractLibTest is Test {
    address coinFiller;
    address outputToken;
    address settlerCompact;

    IsContractLibHarness isContractLib;

    function setUp() public {
        isContractLib = new IsContractLibHarness();
        coinFiller = address(new CoinFiller());
        outputToken = address(new MockERC20("TEST", "TEST", 18));
        settlerCompact = address(new SettlerCompact(address(0)));
    }

    function test_checkCodeSize_known_addresses() external {
        isContractLib.checkCodeSize(coinFiller);

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(makeAddr("coinFiller"));

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(address(0));

        isContractLib.checkCodeSize(outputToken);
        isContractLib.checkCodeSize(settlerCompact);

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(makeAddr("random"));

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(makeAddr("swapper"));
    }
}
