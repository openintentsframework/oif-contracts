// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICrossL2Prover {
    /**
     * @return chainId Source chain identifier
     * @return emittingContract Emitting contract address
     * @return topics Concatenated Event topics
     * @return unindexedData Non-indexed event parameters
     */
    function validateEvent(
        bytes calldata proof
    ) external returns (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData);
}
