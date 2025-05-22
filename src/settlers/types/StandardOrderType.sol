// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputType } from "./MandateOutputType.sol";

struct StandardOrder {
    address user;
    uint256 nonce;
    uint256 originChainId;
    uint32 expires;
    uint32 fillDeadline;
    address localOracle;
    uint256[2][] inputs;
    MandateOutput[] outputs;
}

/**
 * @notice This is the signed Catalyst witness structure. This allows us to more easily collect the order hash.
 * Notice that this is different to both the order data and the ERC7683 order.
 */
struct Mandate {
    uint32 fillDeadline;
    address localOracle;
    // MandateOutput is called MandateOutput
    MandateOutput[] outputs;
}

/**
 * @notice Helper library for the Catalyst order type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library StandardOrderType {
    function orderIdentifier(
        StandardOrder calldata order
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                block.chainid,
                address(this),
                order.user,
                order.nonce,
                order.expires,
                order.fillDeadline,
                order.localOracle,
                order.inputs,
                abi.encode(order.outputs)
            )
        );
    }

    // TheCompact reqquires that our signed struct is provided as a struct named Mandate. However
    bytes constant CATALYST_WITNESS_TYPE_COMPACT_STUB =
        bytes("uint32 fillDeadline,address localOracle,MandateOutput[] outputs)");
    bytes constant BATCH_COMPACT_SUB_TYPES =
        abi.encodePacked(CATALYST_WITNESS_TYPE_COMPACT_STUB, MandateOutputType.MANDATE_OUTPUT_COMPACT_TYPE_STUB);

    // For hashing of our subtypes, we need proper types.
    bytes constant CATALYST_WITNESS_TYPE = abi.encodePacked("Mandate(", BATCH_COMPACT_SUB_TYPES, ")");
    bytes32 constant CATALYST_WITNESS_TYPE_HASH = keccak256(CATALYST_WITNESS_TYPE);

    function witnessHash(
        StandardOrder calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CATALYST_WITNESS_TYPE_HASH,
                order.fillDeadline,
                order.localOracle,
                MandateOutputType.hashOutputs(order.outputs)
            )
        );
    }

    bytes constant BATCH_COMPACT_TYPE_STUB = bytes(
        "BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,uint256[2][] idsAndAmounts,Mandate mandate)"
    );
    bytes constant BATCH_COMPACT_TYPE = abi.encodePacked(BATCH_COMPACT_TYPE_STUB, CATALYST_WITNESS_TYPE);
    bytes32 constant BATCH_COMPACT_TYPE_HASH = keccak256(BATCH_COMPACT_TYPE);

    function compactHash(
        address arbiter,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        StandardOrder calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                BATCH_COMPACT_TYPE_HASH,
                arbiter,
                sponsor,
                nonce,
                expires,
                hashIdsAndAmounts(order.inputs),
                witnessHash(order)
            )
        );
    }

    function hashIdsAndAmounts(
        uint256[2][] calldata inputs
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(inputs));
    }
}
