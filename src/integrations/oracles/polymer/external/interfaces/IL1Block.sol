// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

interface IL1Block {
    /// @notice The latest L1 blockhash.
    function hash() external view returns (bytes32);
}
