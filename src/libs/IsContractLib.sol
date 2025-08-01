// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library IsContractLib {
    error CodeSize0();
    /**
     * @notice Checks if an address has contract code. Reverts with custom error CodeSize0() if size == 0.
     * @dev The intended use of this function is in combination with contracts that do not have code size checks
     * before making transfers.
     * @param addr is the token contract address needs to be checked against.
     */

    function validateContainsCode(
        address addr
    ) internal view {
        uint256 size;
        assembly ("memory-safe") {
            size := extcodesize(addr)
        }
        if (size == 0) revert CodeSize0();
    }
}
