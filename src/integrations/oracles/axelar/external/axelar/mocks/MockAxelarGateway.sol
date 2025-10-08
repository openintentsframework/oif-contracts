// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IAxelarGateway } from "../interfaces/IAxelarGateway.sol";

/**
 * @notice This contract was copied from an external source.
 * @dev Protocol: Axelar General Message Passing (GMP) SDK for Solidity
 * @dev Source:
 * https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/b3f350ba13578c835ded64f7f34b0d5adeeeeb48/contracts/test/mocks/MockGateway.sol#L316
 * @dev Commit Hash: b3f350ba13578c835ded64f7f34b0d5adeeeeb48
 * @dev Copied on: 2025-10-08
 *
 * --- Modifications ---
 *
 * @dev - Functions not used in testing have been removed.
 * @dev - The approveContractCall function has been replaced with a more dev-friendly interface for testing.
 */
contract MockAxelarGateway is IAxelarGateway {
    bytes32 internal constant PREFIX_COMMAND_EXECUTED = keccak256("command-executed");
    bytes32 internal constant PREFIX_CONTRACT_CALL_APPROVED = keccak256("contract-call-approved");

    mapping(bytes32 => bool) public bools;

    /**
     * |* Public Methods *|
     */
    function callContract(
        string calldata destinationChain,
        string calldata destinationContractAddress,
        bytes calldata payload
    ) external {
        emit ContractCall(address(this), destinationChain, destinationContractAddress, keccak256(payload), payload);
    }

    function isContractCallApproved(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) external view override returns (bool) {
        return bools[_getIsContractCallApprovedKey(commandId, sourceChain, sourceAddress, contractAddress, payloadHash)];
    }

    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external override returns (bool valid) {
        bytes32 key = _getIsContractCallApprovedKey(commandId, sourceChain, sourceAddress, address(this), payloadHash);
        valid = bools[key];
        if (valid) bools[key] = false;
    }

    /**
     * |* Getters *|
     */
    function isCommandExecuted(
        bytes32 commandId
    ) public view override returns (bool) {
        return bools[_getIsCommandExecutedKey(commandId)];
    }

    /**
     * |* Self Functions *|
     */
    function approveContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external {
        bytes32 key = _getIsContractCallApprovedKey(commandId, sourceChain, sourceAddress, address(this), payloadHash);
        bools[key] = true;
    }

    /**
     * |* Pure Key Getters *|
     */
    function _getIsCommandExecutedKey(
        bytes32 commandId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PREFIX_COMMAND_EXECUTED, commandId));
    }

    function _getIsContractCallApprovedKey(
        bytes32 commandId,
        string memory sourceChain,
        string memory sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PREFIX_CONTRACT_CALL_APPROVED, commandId, sourceChain, sourceAddress, contractAddress, payloadHash
            )
        );
    }
}
