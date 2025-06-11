// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice Interface for exposing data that oracles can bridge cross-chain.
 */
interface IPayloadCreator {
    struct FillRecord {
        bytes32 orderId;
        bytes32 outputHash;
        bytes32 payloadHash;
    }

    /// @notice Check if a series of fill records are valid.
    /// @param fills Encoded fill records to validate
    /// @return bool Whether all fill records are valid
    function arePayloadsValid(
        bytes calldata fills
    ) external view returns (bool);
}
