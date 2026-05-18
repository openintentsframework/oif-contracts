// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "openzeppelin/access/Ownable.sol";

/**
 * @notice Add chainmapping functionality to an oracle.
 * @dev If this oracle extension is used, it is important that transparent maps are not used; If a chain does not have a
 * corresponding configured id, it cannot be returned as is. The owner can later change this mapping unexpectedly. This
 * is not true for configured mappings.
 */
abstract contract ChainMap is Ownable {
    error AlreadySet();
    error ZeroValue();

    event ChainMapConfigured(uint256 protocolChainIdentifier, uint256 chainId);

    mapping(uint256 protocolChainidentifier => uint256 chainId) public chainIdMap;
    mapping(uint256 chainId => uint256 protocolChainidentifier) public reverseChainIdMap;

    constructor(
        address _owner
    ) Ownable(_owner) { }

    // --- Chain ID Functions --- //

    /**
     * @dev Wrapper for translating chainIds. Intended to override the implementation of the oracle.
     * @param protocolId ChainId of a message.
     * @return chainId "Canonical" chain id.
     */
    function _getMappedChainId(
        uint256 protocolId
    ) internal view virtual returns (uint256 chainId) {
        chainId = chainIdMap[protocolId];
        if (chainId == 0) revert ZeroValue();
    }

    /**
     * @notice Sets an immutable map between 2 chain identifiers.
     * @dev Can only be called once for every chain.
     * @param protocolChainIdentifier Messaging protocol's chain identifier.
     * @param chainId "Canonical" chain id. For EVM, should be block.chainid.
     */
    function setChainMap(
        uint256 protocolChainIdentifier,
        uint256 chainId
    ) external onlyOwner {
        if (protocolChainIdentifier == 0) revert ZeroValue();
        if (chainId == 0) revert ZeroValue();

        if (chainIdMap[protocolChainIdentifier] != 0) revert AlreadySet();
        if (reverseChainIdMap[chainId] != 0) revert AlreadySet();

        chainIdMap[protocolChainIdentifier] = chainId;
        reverseChainIdMap[chainId] = protocolChainIdentifier;

        emit ChainMapConfigured(protocolChainIdentifier, chainId);
    }
}
