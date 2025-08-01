// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice Library for common assembly operations.
library AssemblyLib {
    /**
     * @notice Computes `and(a, b)` in assembly.
     * @dev Does not clean parameters. If both a and b are dirty, c may also be dirty.
     * @param a Left boolean.
     * @param b Right boolean.
     * @return c Whether a and B are both true
     */
    function and(bool a, bool b) internal pure returns (bool c) {
        assembly ("memory-safe") {
            c := and(a, b)
        }
    }
}
