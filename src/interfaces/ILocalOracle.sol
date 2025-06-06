// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @notice Interface for oracles that receive and store attestations
interface ILocalOracle {
    /// @notice Check if data has been attested to
    function isProven(
        uint256 remoteChainId,
        bytes32 remoteOracle,
        bytes32 application,
        bytes32 dataHash
    ) external view returns (bool);

    /// @notice Efficiently verify multiple proofs
    function efficientRequireProven(
        bytes calldata proofSeries
    ) external view;
}
