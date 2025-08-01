// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/// @dev Reverts if signature validation fails.
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}
