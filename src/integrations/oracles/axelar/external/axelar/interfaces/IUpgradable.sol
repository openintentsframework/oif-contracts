// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IImplementation } from "./IImplementation.sol";
import { IOwnable } from "./IOwnable.sol";

/**
 * @notice This interface was copied from an external source.
 * @dev Protocol: Axelar General Message Passing (GMP) SDK for Solidity
 * @dev Source:
 * https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/b3f350ba13578c835ded64f7f34b0d5adeeeeb48/contracts/interfaces/IUpgradable.sol
 * @dev Commit Hash: b3f350ba13578c835ded64f7f34b0d5adeeeeb48
 * @dev Copied on: 2025-10-08
 */

// General interface for upgradable contracts
interface IUpgradable is IOwnable, IImplementation {
    error InvalidCodeHash();
    error InvalidImplementation();
    error SetupFailed();

    event Upgraded(address indexed newImplementation);

    function implementation() external view returns (address);

    function upgrade(address newImplementation, bytes32 newImplementationCodeHash, bytes calldata params) external;
}
