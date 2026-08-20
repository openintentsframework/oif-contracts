// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTRC20 } from "tron-contracts/token/TRC20/utils/SafeTRC20.sol";

import { InputSettlerBase } from "../../../src/input/InputSettlerBase.sol";
import { InputSettlerEscrow } from "../../../src/input/escrow/InputSettlerEscrow.sol";
import { InputSettlerEscrowTron } from "../../../src/input/escrow/InputSettlerEscrowTron.sol";
import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { StandardOrder } from "../../../src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "../../../src/interfaces/IInputSettlerEscrow.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";

import { MockUSDT } from "../../mocks/MockUSDT.sol";
import { InputSettlerEscrowTest } from "./InputSettlerEscrow.t.sol";

/// @notice Runs the full `InputSettlerEscrowTest` suite against the TRON settler variant — deployed with USDT
/// configured and Permit2 hosted at the TRON address — and adds tests for the TRON particularities: USDT payout
/// through `finalise` and `refund`, and input collection through the TRON Permit2 deployment.
contract InputSettlerEscrowTronTest is InputSettlerEscrowTest {
    using LibAddress for address;

    // TRON's Permit2 deployment (TIP-26 CREATE2 derivation), hardcoded in `InputSettlerEscrowTron._PERMIT2`.
    address constant TRON_PERMIT2 = 0xBE365314f2E77FD1257d60C346Bb32DbDa369403;

    MockUSDT usdt;

    function setUp() public virtual override {
        super.setUp();
        // Host a Permit2 instance at the TRON address by copying the canonical runtime code (and its cached domain
        // separator). Signing/verification both read the domain separator from this instance, so they stay
        // self-consistent. The permit2 helpers and the swapper's approval are then repointed at it.
        vm.etch(TRON_PERMIT2, permit2.code);
        permit2 = TRON_PERMIT2;
        vm.prank(swapper);
        token.approve(permit2, type(uint256).max);
    }

    function _deployInputSettler() internal virtual override returns (address) {
        usdt = new MockUSDT("Tether USD", "USDT", 6);
        return address(new InputSettlerEscrowTron(address(usdt)));
    }

    function _snapshotGas(
        string memory name
    ) internal virtual override {
        vm.snapshotGasLastCall("inputSettlerTron", name);
    }

    /// @dev Opens an order escrowing `amount` USDT from the swapper, collected through `transferFrom` (which
    /// returns `true` on the real token).
    function _openUsdtOrder(
        uint32 expires,
        uint128 amount
    ) internal returns (StandardOrder memory order) {
        usdt.mint(swapper, amount);
        vm.prank(swapper);
        usdt.approve(inputSettlerEscrow, amount);

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(usdt))), uint256(amount)];

        order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: expires,
            fillDeadline: expires,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);

        assertEq(usdt.balanceOf(swapper), 0);
        assertEq(usdt.balanceOf(inputSettlerEscrow), amount);
    }

    // -- TRON particularities: USDT payouts -- //

    /// forge-config: default.isolate = true
    function test_finalise_usdt_gas() external {
        test_finalise_usdt(10 ** 6);
    }

    /// @dev USDT, whose `transfer` returns `false` on success, is paid out to the solver on `finalise`.
    function test_finalise_usdt(
        uint128 amount
    ) public {
        vm.assume(amount > 0);

        StandardOrder memory order = _openUsdtOrder(type(uint32).max, amount);

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] =
            InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: uint32(block.timestamp) });

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, solveParams, solver.toIdentifier(), hex"");
        _snapshotGas("EscrowFinaliseUsdt");

        assertEq(usdt.balanceOf(solver), amount);
        assertEq(usdt.balanceOf(inputSettlerEscrow), 0);
    }

    /// @dev A USDT `transfer` that does not debit the escrow reverts the payout.
    function test_finalise_usdt_reverts_when_transfer_moves_no_balance() public {
        uint128 amount = 10 ** 6;
        StandardOrder memory order = _openUsdtOrder(type(uint32).max, amount);

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] =
            InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: uint32(block.timestamp) });

        vm.mockCall(
            address(usdt), abi.encodeWithSelector(usdt.transfer.selector, solver, uint256(amount)), abi.encode(false)
        );

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(SafeTRC20.SafeTRC20FailedOperation.selector, address(usdt)));
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, solveParams, solver.toIdentifier(), hex"");
    }

    /// @dev A plain `InputSettlerEscrow` cannot pay out USDT: `SafeERC20.safeTransfer` treats the `false` return as
    /// a failed transfer. The TRON variant exists to settle these inputs.
    function test_finalise_usdt_reverts_on_base_escrow() public {
        uint128 amount = 10 ** 6;
        inputSettlerEscrow = address(new InputSettlerEscrow());
        StandardOrder memory order = _openUsdtOrder(type(uint32).max, amount);

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] =
            InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: uint32(block.timestamp) });

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(usdt)));
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, solveParams, solver.toIdentifier(), hex"");
    }

    /// forge-config: default.isolate = true
    function test_refund_usdt_gas() external {
        test_refund_usdt(10 ** 6);
    }

    /// @dev USDT is returned to the user on `refund` through the same payout path as `finalise`.
    function test_refund_usdt(
        uint128 amount
    ) public {
        vm.assume(amount > 0);

        uint32 expires = uint32(block.timestamp + 1 days);
        StandardOrder memory order = _openUsdtOrder(expires, amount);

        vm.warp(uint256(expires) + 1);

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        vm.expectEmit();
        emit InputSettlerEscrow.Refunded(orderId);

        InputSettlerEscrow(inputSettlerEscrow).refund(order);
        _snapshotGas("escrowRefundUsdt");

        assertEq(usdt.balanceOf(swapper), amount);
        assertEq(usdt.balanceOf(inputSettlerEscrow), 0);
    }

    // -- TRON particularities: Permit2 -- //

    /// @dev USDT is collected through the TRON Permit2 deployment on `openFor`. Only the TRON Permit2 holds the
    /// swapper's USDT approval, so collection can only succeed through the address returned by `_PERMIT2()`.
    function test_open_for_permit2_usdt(
        uint128 amount,
        uint256 nonce
    ) public {
        vm.assume(amount > 0);

        usdt.mint(swapper, amount);
        vm.prank(swapper);
        usdt.approve(TRON_PERMIT2, type(uint256).max);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(usdt))), uint256(amount)];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: address(0),
            inputs: inputs,
            outputs: new MandateOutput[](0)
        });

        bytes memory signature = getPermit2Signature(swapperPrivateKey, order);

        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).openFor(order, order.user, abi.encodePacked(bytes1(0x00), signature));

        assertEq(usdt.balanceOf(swapper), 0);
        assertEq(usdt.balanceOf(inputSettlerEscrow), amount);
    }
}
