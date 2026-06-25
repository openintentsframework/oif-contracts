// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { InputSettlerEscrow } from "../../../src/input/escrow/InputSettlerEscrow.sol";
import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { StandardOrder } from "../../../src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "../../../src/interfaces/IInputSettlerEscrow.sol";

import { InputSettlerEscrowTestBase } from "./InputSettlerEscrow.base.t.sol";

/// @dev Exposes the internal `_PERMIT2()` hook without overriding it, to read the base default.
contract InputSettlerEscrowExposed is InputSettlerEscrow {
    function exposedPermit2() external view returns (address) {
        return address(_PERMIT2());
    }
}

/// @dev Settler whose Permit2 address is overridden through the `_PERMIT2()` hook.
contract InputSettlerEscrowPermit2Override is InputSettlerEscrow {
    // Arbitrary non-canonical address used to host a Permit2 instance in the override test.
    address constant ALT_PERMIT2 = address(0xa17E12330000000000000000000000000000B33f);

    function _PERMIT2() internal pure override returns (ISignatureTransfer) {
        return ISignatureTransfer(ALT_PERMIT2);
    }

    function exposedPermit2() external view returns (address) {
        return address(_PERMIT2());
    }
}

/// @notice Verifies the `_PERMIT2()` override hook added to InputSettlerEscrow: the base default resolves
/// to the canonical Permit2, and an overriding subclass routes the openFor/permit2 collection through the
/// overridden address.
contract InputSettlerEscrowPermit2OverrideTest is InputSettlerEscrowTestBase {
    address constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // Arbitrary non-canonical address used to host a Permit2 instance in the override test.
    address constant ALT_PERMIT2 = address(0xa17E12330000000000000000000000000000B33f);

    /// @dev End-to-end: an overriding settler must collect inputs via the overridden Permit2, not the canonical one.
    function test_open_for_permit2_routes_through_overridden_address(
        uint128 amount
    ) public {
        vm.assume(amount > 0);

        // Host a Permit2 instance at the non-canonical address by copying the canonical runtime code (and its
        // cached domain separator). Signing/verification both read the domain separator from this instance, so
        // they stay self-consistent.
        vm.etch(ALT_PERMIT2, CANONICAL_PERMIT2.code);

        // Point the settler (and the base test helpers) at the overridden Permit2.
        inputSettlerEscrow = address(new InputSettlerEscrowPermit2Override());
        permit2 = ALT_PERMIT2;

        token.mint(swapper, amount);
        vm.prank(swapper);
        token.approve(ALT_PERMIT2, type(uint256).max);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), uint256(amount)];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        bytes memory signature = getPermit2Signature(swapperPrivateKey, order);

        uint256 swapperBalanceBefore = token.balanceOf(swapper);
        // The settler is freshly deployed, so it starts with no escrowed inputs.
        assertEq(token.balanceOf(inputSettlerEscrow), 0);

        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).openFor(order, order.user, abi.encodePacked(bytes1(0x00), signature));

        // Inputs were pulled through the overridden Permit2 and escrowed in the settler.
        assertEq(token.balanceOf(swapper), swapperBalanceBefore - amount);
        assertEq(token.balanceOf(inputSettlerEscrow), amount);
    }
}
