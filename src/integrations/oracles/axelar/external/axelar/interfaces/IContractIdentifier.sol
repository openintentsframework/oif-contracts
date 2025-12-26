// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @notice This interface was copied from an external source.
 * @dev Protocol: Axelar General Message Passing (GMP) SDK for Solidity
 * @dev Source:
 * https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/b3f350ba13578c835ded64f7f34b0d5adeeeeb48/contracts/interfaces/IContractIdentifier.sol
 * @dev Commit Hash: b3f350ba13578c835ded64f7f34b0d5adeeeeb48
 * @dev Copied on: 2025-10-08
 */

// General interface for upgradable contracts
interface IContractIdentifier {
    /**
     * @notice Returns the contract ID. It can be used as a check during upgrades.
     * @dev Meant to be overridden in derived contracts.
     * @return bytes32 The contract ID
     */
    function contractId() external pure returns (bytes32);
}
