// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputType } from "./MandateOutputType.sol";

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
    /**
     * @notice Computes the Compact claim hash, as it is the one used as the order id.
     */
    function orderIdentifier(
        MultichainOrderComponent calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                order // TODO: Compute claimHash
            )
        );
    }

    bytes constant BATCH_COMPACT_SUB_TYPES = StandardOrderType.BATCH_COMPACT_SUB_TYPES;

    function witnessHash(
        MultichainOrderComponent calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                // Same witness as StandardOrderq
                StandardOrderType.CATALYST_WITNESS_TYPE_HASH,
                order.fillDeadline,
                order.localOracle,
                MandateOutputType.hashOutputs(order.outputs)
            )
        );
    }
}
