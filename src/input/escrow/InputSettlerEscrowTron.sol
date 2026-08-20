// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { ITRC20 } from "tron-contracts/token/TRC20/ITRC20.sol";
import { SafeTRC20 } from "tron-contracts/token/TRC20/utils/SafeTRC20.sol";

import { InputSettlerEscrow } from "./InputSettlerEscrow.sol";

/**
 * @title OIF Input Settler (escrow variant) for TRON.
 * @notice TRON USDT (`TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`) returns `false` from `transfer` even on a *successful*
 * transfer (while reverting on real failure). OpenZeppelin's `SafeERC20.safeTransfer`, used by {InputSettlerEscrow}
 * to pay out escrowed inputs, reads that `false` as a failure and reverts — locking USDT in the escrow.
 *
 * This variant overrides the {InputSettlerEscrow-_transfer} payout hook to settle inputs with {SafeTRC20}, routing
 * the configured {USDT} token through {SafeTRC20-safeTransferChecked} (which ignores the boolean and verifies the
 * transfer by the sender's balance delta) and every other token through the regular {SafeTRC20-safeTransfer}.
 *
 * Only the outbound payout needs this treatment. The inbound `transferFrom` performed on `open` is unaffected,
 * because USDT's `transferFrom` correctly returns `true`.
 *
 * The USDT address is supplied at construction so the same code can be deployed against different USDT deployments
 * (and so a non-USDT chain can simply pass `address(0)`, disabling the special path).
 */
contract InputSettlerEscrowTron is InputSettlerEscrow {
    /// @notice Address of the USDT token whose `transfer` returns `false` on success; `address(0)` to disable.
    address public immutable USDT;

    constructor(
        address usdt
    ) {
        USDT = usdt;
    }

    /**
     * @dev Pays out an escrowed input with {SafeTRC20}, sending the configured {USDT} via
     * {SafeTRC20-safeTransferChecked}.
     */
    function _transfer(
        address token,
        address destination,
        uint256 amount
    ) internal virtual override {
        if (token == USDT) SafeTRC20.safeTransferChecked(ITRC20(token), destination, amount);
        else SafeTRC20.safeTransfer(ITRC20(token), destination, amount);
    }

    /**
     * @notice Returns the Permit2 contract used to collect escrowed inputs on TRON.
     * @dev TRON's Permit2 is deployed at `TTJxU3P8rHycAyFY4kVtGNfmnMH4ezcuM9` (tagged `SUN: Permit2`), the
     * deployment TRON protocols integrate against and that holds user approvals. TIP-26 derives CREATE2 addresses
     * with the `0x41` hash prefix, giving TRON its own Permit2 address.
     * @return The Permit2 (ISignatureTransfer) contract on TRON.
     */
    function _PERMIT2() internal pure override returns (ISignatureTransfer) {
        return ISignatureTransfer(0xBE365314f2E77FD1257d60C346Bb32DbDa369403);
    }
}
