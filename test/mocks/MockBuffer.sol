// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IBuffer {
    error UnknownParentChainBlockHash(uint256 parentChainBlockNumber);

    function receiveHashes(
        uint256 firstBlockNumber,
        bytes32[] memory blockHashes
    ) external;

    function parentChainBlockHash(
        uint256 parentChainBlockNumber
    ) external view returns (bytes32);
}

contract MockBuffer is IBuffer {
    mapping(uint256 => bytes32) public parentChainBlockHashes;

    function receiveHashes(
        uint256 firstBlockNumber,
        bytes32[] memory blockHashes
    ) external {
        // Implementation
        for (uint256 i = 0; i < blockHashes.length; i++) {
            parentChainBlockHashes[firstBlockNumber + i] = blockHashes[i];
        }
    }

    function parentChainBlockHash(
        uint256 parentChainBlockNumber
    ) external view returns (bytes32) {
        // Implementation

        if (parentChainBlockHashes[parentChainBlockNumber] == bytes32(0)) {
            revert UnknownParentChainBlockHash(parentChainBlockNumber);
        }

        return parentChainBlockHashes[parentChainBlockNumber];
    }
}
