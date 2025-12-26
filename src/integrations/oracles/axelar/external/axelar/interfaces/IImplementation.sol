// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IContractIdentifier } from "./IContractIdentifier.sol";

/**
 * @notice This interface was copied from an external source.
 * @dev Protocol: Axelar General Message Passing (GMP) SDK for Solidity
 * @dev Source:
 * https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/b3f350ba13578c835ded64f7f34b0d5adeeeeb48/contracts/interfaces/IImplementation.sol
 * @dev Commit Hash: b3f350ba13578c835ded64f7f34b0d5adeeeeb48
 * @dev Copied on: 2025-10-08
 */
interface IImplementation is IContractIdentifier {
    error NotProxy();

    function setup(
        bytes calldata data
    ) external;
}
