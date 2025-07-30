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
    address localOracle;
    uint256[2][] inputs;
    MandateOutput[] outputs;
    bytes32[] additionalChains; // <-- Fix this?
}

/**
 * @notice Helper library for the multichain order type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library MultichainOrderComponentType {
    /**
     * @dev If this function is used in a context where correctness of the identifier is important, the chainIdField
     * needs to be validated against block.chainid
     */
    function orderIdentifier(
        MultichainOrderComponent calldata order
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                // TODO: How to encode address(this) field. If this field is present, how do we do cross-vm / zk-sync
                // compatibility?
                address(this),
                order.user,
                order.nonce,
                order.expires,
                order.fillDeadline,
                order.localOracle,
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
        // TODO: chainIndex in [0, numSegments]
        // TODO: use assembly for insert.
        bytes32[] memory claimStructure = new bytes32[](numSegments);
        for (uint256 i = 0; i < numSegments; ++i) {
            uint256 additionalChainsIndex;
            assembly ("memory-safe") {
                // If we have already inserted "inputs" we need to remove 1 from the index.
                additionalChainsIndex := sub(i, gt(i, chainIndex))
            }
            claimStructure[i] = chainIndex == i ? inputHash : additionalChains[additionalChainsIndex];
        }
        // Length is implied by size.
        return keccak256(abi.encodePacked(claimStructure));
    }

    function hashInputs(uint256 chainId, uint256[2][] calldata inputs) internal pure returns (bytes32) {
        // TODO: If we use this straight, change to assembly calldata copy.
        // TODO: Alternative is to use abi.encodePacked. Length is implicit though size.
        return keccak256(abi.encodePacked(chainId, inputs));
    }
}
