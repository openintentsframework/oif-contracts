// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Provides helpers to verify if an output has been submitted to the right consumer.
 */
library OutputVerificationLib {
    error WrongChain(uint256 expected, uint256 actual);
    error WrongOutputSettler(bytes32 addressThis, bytes32 expected);

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
        if (bytes32(uint256(uint160(address(this)))) != outputSettler) {
            revert WrongOutputSettler(bytes32(uint256(uint160(address(this)))), outputSettler);
        }
    }
}
