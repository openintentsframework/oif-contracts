// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @notice Interface for validating payloads before sending
interface IPayloadValidator {
    function arePayloadsValid(
        bytes32[] calldata payloads
    ) external view returns (bool);
}
