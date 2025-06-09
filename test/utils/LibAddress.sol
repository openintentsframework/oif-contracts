// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library LibAddress {
    /**
     * @notice Converts an Ethereum address to a bytes32 identifier that can be used across chains.
     * @param addr The address to convert.
     * @return _ The bytes32 identifier.
     */
    // TODO: This should be moved as a library function inside the protocol and used in the protocol as well.
    function toIdentifier(
        address addr
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}
