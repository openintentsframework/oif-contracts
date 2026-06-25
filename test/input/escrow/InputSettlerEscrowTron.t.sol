// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockUSDT } from "../../mocks/MockUSDT.sol";

import { InputSettlerEscrow } from "../../../src/input/escrow/InputSettlerEscrow.sol";
import { InputSettlerEscrowTron } from "../../../src/input/escrow/InputSettlerEscrowTron.sol";

/// @dev Exposes the internal `_resolveLock` payout, putting the order in `Deposited` first (the state `open` leaves it
/// in), so the outbound-transfer behaviour can be tested without the full open/fill/prove/finalise flow.
contract InputSettlerEscrowHarness is InputSettlerEscrow {
    function payOut(
        bytes32 orderId,
        uint256[2][] calldata inputs,
        address destination
    ) external {
        orderStatus[orderId] = OrderStatus.Deposited;
        _resolveLock(orderId, inputs, destination, OrderStatus.Claimed);
    }
}

contract InputSettlerEscrowTronHarness is InputSettlerEscrowTron {
    constructor(
        address usdt
    ) InputSettlerEscrowTron(usdt) { }

    function payOut(
        bytes32 orderId,
        uint256[2][] calldata inputs,
        address destination
    ) external {
        orderStatus[orderId] = OrderStatus.Deposited;
        _resolveLock(orderId, inputs, destination, OrderStatus.Claimed);
    }
}

contract InputSettlerEscrowTronTest is Test {
    MockUSDT usdt;
    MockERC20 token;
    InputSettlerEscrowHarness baseEscrow;
    InputSettlerEscrowTronHarness tronEscrow;

    address solver = makeAddr("solver");
    bytes32 constant ORDER_ID = bytes32(uint256(1));
    uint256 constant AMOUNT = 1000;

    function setUp() public {
        usdt = new MockUSDT("Tether USD", "USDT", 6);
        token = new MockERC20("Mock", "MOCK", 18);
        baseEscrow = new InputSettlerEscrowHarness();
        tronEscrow = new InputSettlerEscrowTronHarness(address(usdt));
    }

    function _inputs(
        address t,
        uint256 amount
    ) internal pure returns (uint256[2][] memory inputs) {
        inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(t));
        inputs[0][1] = amount;
    }

    /// @dev Demonstrates the bug: the base escrow's `SafeERC20.safeTransfer` reads USDT's `false` as a failure.
    function test_baseEscrow_reverts_on_usdt() public {
        usdt.mint(address(baseEscrow), AMOUNT);
        vm.expectRevert();
        baseEscrow.payOut(ORDER_ID, _inputs(address(usdt), AMOUNT), solver);
    }

    /// @dev The Tron variant pays out USDT despite the `false` return.
    function test_tronEscrow_pays_out_usdt() public {
        usdt.mint(address(tronEscrow), AMOUNT);
        tronEscrow.payOut(ORDER_ID, _inputs(address(usdt), AMOUNT), solver);
        assertEq(usdt.balanceOf(solver), AMOUNT);
    }

    /// @dev Non-USDT tokens still settle through the regular `SafeTRC20.safeTransfer` path.
    function test_tronEscrow_pays_out_regular_token() public {
        token.mint(address(tronEscrow), AMOUNT);
        tronEscrow.payOut(ORDER_ID, _inputs(address(token), AMOUNT), solver);
        assertEq(token.balanceOf(solver), AMOUNT);
    }
}
