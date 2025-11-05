// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputType } from "./MandateOutputType.sol";

struct MultichainOrderComponent {
    address user;
    uint256 nonce;
    uint256 chainIdField;
    uint256 chainIndex;
    uint32 expires;
    uint32 fillDeadline;
    address inputOracle;
    uint256[2][] inputs;
    MandateOutput[] outputs;
    bytes32[] additionalChains;
}

/**
 * @notice Helper library for the multichain order type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library MultichainOrderComponentType {
    error ChainIndexOutOfRange(uint256 chainIndex, uint256 numSegments);

    /**
     * @dev If this function is used in a context where correctness of the identifier is important, the chainIdField
     * needs to be validated against block.chainid
     */
    function orderIdentifier(
        MultichainOrderComponent calldata order
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                address(this),
                order.user,
                order.nonce,
                order.expires,
                order.fillDeadline,
                order.inputOracle,
                constructInputHash(order.chainIdField, order.chainIndex, order.inputs, order.additionalChains),
                abi.encode(order.outputs)
            )
        );
    }

    /**
     * @notice Generates a shared identical input hash for a list of list of inputs.
     * Assume that you have a list inputs:
     * - a: [a, [1, 1], [1,2]] => ha = keccak256(abi.encodePacked("a", a))
     * - b: [b, [2, 1], [2,2]] => hb = keccak256(abi.encodePacked("b", b))
     * - c: [c, [3, 1], [3,2]] => hc = keccak256(abi.encodePacked("c", c))
     * And wants to compute the hash: h = keccak256(abi.encodePacked(a, b, c)))
     * Given 1, b, and [ha, hc] the function will compute h.
     */
    function constructInputHash(
        uint256 inputsChainId,
        uint256 chainIndex,
        uint256[2][] calldata inputs,
        bytes32[] calldata additionalChains
    ) internal pure returns (bytes32) {
        bytes32 inputHash = hashInputs(inputsChainId, inputs);
        uint256 numSegments = additionalChains.length + 1;
        if (numSegments <= chainIndex) revert ChainIndexOutOfRange(chainIndex, numSegments);
        bytes memory claimStructure = new bytes(32 * numSegments);
        uint256 p;
        assembly ("memory-safe") {
            p := add(claimStructure, 0x20)
        }
        for (uint256 i = 0; i < numSegments; ++i) {
            uint256 additionalChainsIndex;
            assembly ("memory-safe") {
                // If we have already inserted "inputs" we need to remove 1 from the index.
                additionalChainsIndex := sub(i, gt(i, chainIndex))
            }
            bytes32 inputHashElement = chainIndex == i ? inputHash : additionalChains[additionalChainsIndex];
            assembly ("memory-safe") {
                mstore(add(p, mul(i, 0x20)), inputHashElement)
            }
        }
        // Length is implied by size.
        return keccak256(claimStructure);
    }

    /**
     * @notice Internal pure function for deriving the hash of ids and amounts with a provided chainId salt.
     * This function returns keccak256(abi.encodePacked(chainId, idsAndAmounts))
     * @param chainId Chain identifier used to salt the input hash.
     * @param idsAndAmounts An array of ids and amounts.
     * @return inputHash The hash of the ids and amounts salted with chainId.
     * @dev This function expects that the calldata of idsAndAmounts will have bounds
     * checked elsewhere; using it without this check occurring elsewhere can result in
     * erroneous hash values.
     */
    function hashInputs(
        uint256 chainId,
        uint256[2][] calldata idsAndAmounts
    ) internal pure returns (bytes32 inputHash) {
        assembly ("memory-safe") {
            // Retrieve the free memory pointer; memory will be left dirtied.
            let ptr := mload(0x40)

            // Get the total length of the calldata slice.
            // Each element of the array consists of 2 words.
            let len := mul(idsAndAmounts.length, 0x40)

            // Store the chainId at the pointer.
            mstore(ptr, chainId)

            // Copy calldata into memory after the chainId.
            calldatacopy(add(0x20, ptr), idsAndAmounts.offset, len)

            // Compute the hash of the calldata that has been copied into memory.
            inputHash := keccak256(ptr, add(len, 0x20))
        }
    }
}
