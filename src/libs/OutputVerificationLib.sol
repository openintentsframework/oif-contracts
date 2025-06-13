// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "./LibAddress.sol";
import { MandateOutput } from "./MandateOutputEncodingLib.sol";

/**
 * @notice Provides helpers to verify if an output has been submitted to the right consumer.
 */
library OutputVerificationLib {
    error WrongChain(uint256 expected, uint256 actual);
    error WrongOutputSettler(bytes32 addressThis, bytes32 expected);

    using LibAddress for address;

    /**
     * @param chainId Expected chain id. Validated to match block.chainId.
     * @dev The canonical chain id is used for outputs.
     */
    function _isThisChain(
        uint256 chainId
    ) internal view {
        if (chainId != block.chainid) revert WrongChain(uint256(chainId), block.chainid);
    }

    /**
     * @notice Validate the remote oracle address is this contract.
     */
    function _isThisOutputSettler(
        bytes32 outputSettler
    ) internal view {
        if (address(this).toIdentifier() != outputSettler) {
            revert WrongOutputSettler(address(this).toIdentifier(), outputSettler);
        }
    }
}
