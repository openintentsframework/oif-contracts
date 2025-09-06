// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputType } from "./MandateOutputType.sol";

import { LibAddress } from "../../libs/LibAddress.sol";
import { StandardOrderType } from "./StandardOrderType.sol";

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
    bytes32[] additionalChains;
}

struct Mandate {
    uint32 fillDeadline;
    address localOracle;
    MandateOutput[] outputs;
}

/**
 * @notice Helper library for the multichain order type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library MultichainCompactOrderType {
    using LibAddress for uint256;

    bytes32 constant MULTICHAIN_COMPACT_TYPEHASH_WITH_WITNESS = keccak256(
        bytes(
            "MultichainCompact(address sponsor,uint256 nonce,uint256 expires,Element[] elements)Element(address arbiter,uint256 chainId,Lock[] commitments)Lock(bytes12 lockTag,address token,uint256 amount)Mandate(uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
        )
    ); // TODO: validate

    bytes32 constant ELEMENTS_COMPACT_TYPEHASH_WITH_WITNESS = keccak256(
        bytes(
            "Element(address arbiter,uint256 chainId,Lock[])Lock(bytes12 lockTag,address token,uint256 amount)Mandate(uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
        )
    ); // TODO: validate

    bytes32 constant LOCK_COMPACT_TYPEHASH = keccak256(bytes("Lock(bytes12 lockTag,address token,uint256 amount)"));

    function inputsToLocksHash(
        uint256[2][] calldata inputs
    ) internal pure returns (bytes32) {
        uint256 numInputs = inputs.length;
        bytes memory lockHashes = new bytes(32 * numInputs);
        uint256 p;
        assembly ("memory-safe") {
            p := add(lockHashes, 0x20)
        }
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];
            bytes32 lockHash = keccak256(
                abi.encode(LOCK_COMPACT_TYPEHASH, bytes12(bytes32(input[0])), input[0].fromIdentifier(), input[1])
            );
            assembly ("memory-safe") {
                mstore(add(p, mul(i, 0x20)), lockHash)
            }
        }
        return keccak256(lockHashes);
    }

    function insertAndHash(bytes32 elem, uint256 index, bytes32[] calldata arr) internal pure returns (bytes32) {
        uint256 numElements = arr.length + 1;
        bytes memory newArr = new bytes(32 * numElements);
        uint256 p;
        assembly ("memory-safe") {
            p := add(newArr, 0x20)
        }
        for (uint256 i; i < numElements; ++i) {
            if (index == i) {
                assembly ("memory-safe") {
                    mstore(add(p, mul(i, 0x20)), elem)
                }
                continue;
            }
            // If we have already inserted elem, then i is ahead by 1
            uint256 selectFromIndexAt = index < i ? i - 1 : i; // TODO: sub(i, gt(i, index))
            bytes32 elementToInsert = arr[selectFromIndexAt];
            assembly ("memory-safe") {
                mstore(add(p, mul(i, 0x20)), elementToInsert)
            }
        }
        return keccak256(newArr);
    }

    /**
     * @notice Computes the Compact claim hash, as it is the one used as the order id.
     */
    function orderIdentifier(
        MultichainOrderComponent calldata order
    ) internal view returns (bytes32) {
        // Compute the element hash of this chain.
        bytes32 elementHash = keccak256(
            abi.encode(
                ELEMENTS_COMPACT_TYPEHASH_WITH_WITNESS,
                address(this),
                block.chainid, // todo: validate,
                inputsToLocksHash(order.inputs),
                witnessHash(order)
            )
        );
        // Insert the element hash into the array of the other provided element.
        bytes32 hashOfElements = insertAndHash(elementHash, order.chainIndex, order.additionalChains);

        return keccak256(
            abi.encode(MULTICHAIN_COMPACT_TYPEHASH_WITH_WITNESS, order.user, order.nonce, order.expires, hashOfElements)
        );
    }

    bytes constant BATCH_COMPACT_SUB_TYPES = StandardOrderType.BATCH_COMPACT_SUB_TYPES;

    function witnessHash(
        MultichainOrderComponent calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                // Same witness as StandardOrder
                StandardOrderType.CATALYST_WITNESS_TYPE_HASH,
                order.fillDeadline,
                order.localOracle,
                MandateOutputType.hashOutputs(order.outputs)
            )
        );
    }
}
