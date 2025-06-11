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

    function arePayloadsValid(
        FillRecord[] calldata fills
    ) external view returns (bool);
}
