// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { InputSettlerCompact } from "../../src/input/compact/InputSettlerCompact.sol";
import { IsContractLib } from "../../src/libs/IsContractLib.sol";
import { OutputSettlerCoin } from "../../src/output/coin/OutputSettlerCoin.sol";

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
    address outputSettlerCoin;
    address outputToken;
    address inputSettlerCompact;

    IsContractLibHarness isContractLib;

    function setUp() public {
        isContractLib = new IsContractLibHarness();
        outputSettlerCoin = address(new OutputSettlerCoin());
        outputToken = address(new MockERC20("TEST", "TEST", 18));
        inputSettlerCompact = address(new InputSettlerCompact(address(0)));
    }

    function test_checkCodeSize_known_addresses() external {
        isContractLib.checkCodeSize(outputSettlerCoin);

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(makeAddr("outputSettlerCoin"));

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(address(0));

        isContractLib.checkCodeSize(outputToken);
        isContractLib.checkCodeSize(inputSettlerCompact);

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(makeAddr("random"));

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.checkCodeSize(makeAddr("swapper"));
    }
}
