// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @notice This interface was copied from an external source.
 * @dev Protocol: Axelar General Message Passing (GMP) SDK for Solidity
 * @dev Source:
 * https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/b3f350ba13578c835ded64f7f34b0d5adeeeeb48/contracts/interfaces/IOwnable.sol
 * @dev Commit Hash: b3f350ba13578c835ded64f7f34b0d5adeeeeb48
 * @dev Copied on: 2025-10-08
 */

/**
 * @title IOwnable Interface
 * @notice IOwnable is an interface that abstracts the implementation of a
 * contract with ownership control features. It's commonly used in upgradable
 * contracts and includes the functionality to get current owner, transfer
 * ownership, and propose and accept ownership.
 */
interface IOwnable {
    error NotOwner();
    error InvalidOwner();
    error InvalidOwnerAddress();

    event OwnershipTransferStarted(address indexed newOwner);
    event OwnershipTransferred(address indexed newOwner);

    /**
     * @notice Returns the current owner of the contract.
     * @return address The address of the current owner
     */
    function owner() external view returns (address);

    /**
     * @notice Returns the address of the pending owner of the contract.
     * @return address The address of the pending owner
     */
    function pendingOwner() external view returns (address);

    /**
     * @notice Transfers ownership of the contract to a new address
     * @param newOwner The address to transfer ownership to
     */
    function transferOwnership(
        address newOwner
    ) external;

    /**
     * @notice Proposes to transfer the contract's ownership to a new address.
     * The new owner needs to accept the ownership explicitly.
     * @param newOwner The address to transfer ownership to
     */
    function proposeOwnership(
        address newOwner
    ) external;

    /**
     * @notice Transfers ownership to the pending owner.
     * @dev Can only be called by the pending owner
     */
    function acceptOwnership() external;
}
