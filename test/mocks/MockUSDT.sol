// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MockERC20 } from "./MockERC20.sol";

/// @dev Mimics TRON USDT (`TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`): `transfer` performs the transfer (reverting on
/// failure) but returns `false` even on success. `transferFrom` is left returning `true`, as on the real contract.
contract MockUSDT is MockERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) MockERC20(name_, symbol_, decimals_) { }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        super.transfer(to, amount);
        return false;
    }
}
