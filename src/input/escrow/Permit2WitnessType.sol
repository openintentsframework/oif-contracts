// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { GaslessCrossChainOrder, OnchainCrossChainOrder } from "../../interfaces/IERC7683.sol";
import { MandateOutput, MandateOutputType } from "../types/MandateOutputType.sol";

/**
 * @dev The ERC7683 order uses the same order type as TheCompact orders. However, we have a different witness.
 */
import { StandardOrder } from "../types/StandardOrderType.sol";

/**
 * @notice The signed witness / mandate used for the permit2 transaction.
 */
struct Permit2Witness {
    uint32 expires;
    // uint32 fillDeadline;
    address localOracle;
    uint256[2][] inputs;
    MandateOutput[] outputs;
}

/**
 * @notice Helper library for the Catalyst order type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library Permit2WitnessType {
    // TODO: performance testing of writing types in their entirety.
    bytes constant PERMIT2_WITNESS_TYPE_STUB = abi.encodePacked(
        "Permit2Witness(uint32 expires,address localOracle,uint256[2][] inputs,MandateOutput[] outputs)"
    );

    // M comes earlier than P.
    bytes constant PERMIT2_WITNESS_TYPE = abi.encodePacked(
        "Permit2Witness(uint32 expires,address localOracle,uint256[2][] inputs,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
    );

    bytes32 constant PERMIT2_WITNESS_TYPE_HASH = keccak256(PERMIT2_WITNESS_TYPE);

    bytes constant PERMIT2_PERMIT2_TYPESTRING = abi.encodePacked(
        "Permit2Witness witness)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)TokenPermissions(address token,uint256 amount)Permit2Witness(uint32 expires,address localOracle,uint256[2][] inputs,MandateOutput[] outputs)"
    );

    function Permit2WitnessHash(
        StandardOrder calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PERMIT2_WITNESS_TYPE_HASH,
                order.expires,
                order.localOracle,
                keccak256(abi.encodePacked(order.inputs)),
                MandateOutputType.hashOutputs(order.outputs)
            )
        );
    }

    /**
     * @notice Internal pure function for deriving the hash of ids and amounts provided.
     * @param idsAndAmounts      An array of ids and amounts.
     * @return idsAndAmountsHash The hash of the ids and amounts.
     * @dev From TheCompact src/lib/HashLib.sol
     * This function expects that the calldata of idsAndAmounts will have bounds
     * checked elsewhere; using it without this check occurring elsewhere can result in
     * erroneous hash values.
     */
    function toIdsAndAmountsHash(
        uint256[2][] calldata idsAndAmounts
    ) internal pure returns (bytes32 idsAndAmountsHash) {
        assembly ("memory-safe") {
            // Retrieve the free memory pointer; memory will be left dirtied.
            let ptr := mload(0x40)

            // Get the total length of the calldata slice.
            // Each element of the array consists of 2 words.
            let len := mul(idsAndAmounts.length, 0x40)

            // Copy calldata into memory at the free memory pointer.
            calldatacopy(ptr, idsAndAmounts.offset, len)

            // Compute the hash of the calldata that has been copied into memory.
            idsAndAmountsHash := keccak256(ptr, len)
        }
    }
}
