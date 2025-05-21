// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { CoinFiller } from "src/fillers/coin/CoinFiller.sol";

import { CompactSettler } from "src/settlers/compact/CompactSettler.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

import { IsContractLib } from "src/libs/IsContractLib.sol";

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
    address compactSettler;

    IsContractLibHarness isContractLib;

    function setUp() public {
        isContractLib = new IsContractLibHarness();
        coinFiller = address(new CoinFiller());
        outputToken = address(new MockERC20("TEST", "TEST", 18));
        compactSettler = address(new CompactSettler(address(0), address(0)));
    }

    function test_checkCodeSize_known_addresses() external {
        isContractLib.checkCodeSize(coinFiller);

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(makeAddr("coinFiller"));

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(address(0));

        isContractLib.checkCodeSize(outputToken);
        isContractLib.checkCodeSize(compactSettler);

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(makeAddr("random"));

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(makeAddr("swapper"));
    }
}
