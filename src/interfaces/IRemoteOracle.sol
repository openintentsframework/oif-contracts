// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @notice Interface for oracles that send proofs to other chains
interface IRemoteOracle {
    /// @notice Submit proofs to be sent to other chains
    function submit(address proofSource, bytes[] calldata payloads) external payable returns (uint256 refund);
}
