// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice Interface for exposing data that oracles can bridge cross-chain.
 */
interface IPayloadCreator {
    function arePayloadsValid(
        bytes[] calldata payloads
    ) external view returns (bool);
}
