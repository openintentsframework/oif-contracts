// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputType } from "./MandateOutputType.sol";

struct StandardOrder {
    address user;
    uint256 nonce;
    uint256 originChainId;
    uint32 expires;
    uint32 fillDeadline;
    address inputOracle;
    uint256[2][] inputs;
    MandateOutput[] outputs;
}

/**
 * @notice This is the signed Compact witness structure. This allows us to more easily collect the order hash.
 * Notice that this is different to both the order data and the ERC7683 order.
 */
struct Mandate {
    uint32 fillDeadline;
    address inputOracle;
    MandateOutput[] outputs;
}

/**
 * @notice Helper library for the StandardOrder type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library StandardOrderType {
    using StandardOrderType for bytes;

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
                order.inputOracle,
                keccak256(abi.encodePacked(order.inputs)),
                abi.encode(order.outputs)
            )
        );
    }

    // --- Witness Helpers --- //

    /// @dev TheCompact needs us to provide the type without the last ")"
    bytes constant BATCH_COMPACT_SUB_TYPES = bytes(
        "uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context"
    );

    /// @dev For hashing of our subtypes, we need proper types.
    bytes constant CATALYST_WITNESS_TYPE = abi.encodePacked(
        "Mandate(uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)"
    );
    bytes32 constant CATALYST_WITNESS_TYPE_HASH = keccak256(CATALYST_WITNESS_TYPE);

    /**
     * @notice Computes the Compact witness of derived from a StandardOrder
     * @param order StandardOrder to derived the witness from.
     * @return witness hash.
     */
    function witnessHash(
        StandardOrder calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CATALYST_WITNESS_TYPE_HASH,
                order.fillDeadline,
                order.inputOracle,
                MandateOutputType.hashOutputs(order.outputs)
            )
        );
    }
}
