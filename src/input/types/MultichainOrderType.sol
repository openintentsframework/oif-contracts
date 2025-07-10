// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputType } from "./MandateOutputType.sol";

// TODO: Should this field include the input settler?
struct MultichainInput {
    uint256 inputChainId;
    bytes32 token;
    uint256 amount;
}

struct MultichainOrder {
    address user;
    uint256 nonce;
    uint32 expires;
    uint32 fillDeadline;
    address localOracle;
    MultichainInput[] inputs;
    MandateOutput[] outputs;
}

/**
 * @notice Helper library for the multichain order type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library MultichainOrderType {
    function orderIdentifier(
        MultichainOrder calldata order
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                // TODO: How to encode address(this) field. If this field is present, how do we do cross-vm / zk-sync compatibility? 
                address(this),
                order.user,
                order.nonce,
                order.expires,
                order.fillDeadline,
                order.localOracle,
                abi.encode(order.inputs),
                abi.encode(order.outputs)
            )
        );
    }
}
