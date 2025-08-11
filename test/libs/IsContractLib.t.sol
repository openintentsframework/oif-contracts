// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { InputSettlerCompact } from "../../src/input/compact/InputSettlerCompact.sol";
import { IsContractLib } from "../../src/libs/IsContractLib.sol";
import { OutputSettlerSimple } from "../../src/output/simple/OutputSettlerSimple.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

/// @dev harness is used to place the revert at a lower call depth than our current.
contract IsContractLibHarness {
    function validateContainsCode(
        address addr
    ) external view {
        IsContractLib.validateContainsCode(addr);
    }
}

contract IsContractLibTest is Test {
    address outputSettlerCoin;
    address outputToken;
    address inputSettlerCompact;

    IsContractLibHarness isContractLib;

    function setUp() public {
        isContractLib = new IsContractLibHarness();
        outputSettlerCoin = address(new OutputSettlerSimple());
        outputToken = address(new MockERC20("TEST", "TEST", 18));
        inputSettlerCompact = address(new InputSettlerCompact(address(0)));
    }

    function test_validateContainsCode_known_addresses() external {
        isContractLib.validateContainsCode(outputSettlerCoin);

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.validateContainsCode(makeAddr("outputSettlerCoin"));

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.validateContainsCode(address(0));

        isContractLib.validateContainsCode(outputToken);
        isContractLib.validateContainsCode(inputSettlerCompact);

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.validateContainsCode(makeAddr("random"));

        vm.expectRevert(abi.encodeWithSignature("CodeSize0()"));
        isContractLib.validateContainsCode(makeAddr("swapper"));
    }
}
