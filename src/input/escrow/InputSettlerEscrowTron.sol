// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// NOTE: SafeTRC20 is imported from OpenZeppelin's tron-contracts, pinned (as a git submodule) to the commit that
// introduces `safeTransferUSDT`: OpenZeppelin/tron-contracts@ae352da. Once that change is merged, the submodule
// should be repointed to tron-contracts `master`.
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
 * the configured {USDT} token through {SafeTRC20-safeTransferUSDT} (which ignores the boolean and verifies the
 * transfer by the recipient's balance delta) and every other token through the regular {SafeTRC20-safeTransfer}.
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
     * @dev Pays out an escrowed input with {SafeTRC20}, sending the configured {USDT} via {SafeTRC20-safeTransferUSDT}.
     */
    function _transfer(
        address token,
        address destination,
        uint256 amount
    ) internal virtual override {
        if (token == USDT) SafeTRC20.safeTransferUSDT(ITRC20(token), destination, amount);
        else SafeTRC20.safeTransfer(ITRC20(token), destination, amount);
    }
}
