// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputType } from "../types/MandateOutputType.sol";
import { StandardOrder } from "../types/StandardOrderType.sol";

/**
 * @notice The signed witness / mandate used for the permit2 transaction.
 */
struct Permit2Witness {
    uint32 expires;
    // uint32 fillDeadline; // TODO: fillDeadline is the openDeadline thus is still signed.
    address localOracle;
    MandateOutput[] outputs;
}

/**
 * @notice Helper library for the Permit2 Witness type for StandardOrder.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no sub-types.
 * TYPE: Is complete including sub-types.
 */
library Permit2WitnessType {
    bytes constant PERMIT2_WITNESS_TYPE_STUB = abi.encodePacked(
        "Permit2Witness(uint32 expires,address localOracle,uint256[2][] inputs,MandateOutput[] outputs)"
    );

    // M comes earlier than P.
    bytes constant PERMIT2_WITNESS_TYPE = abi.encodePacked(
        "Permit2Witness(uint32 expires,address localOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
    );

    bytes32 constant PERMIT2_WITNESS_TYPE_HASH = keccak256(PERMIT2_WITNESS_TYPE);

    /// @notice Typestring for handed to Permit2.
    string constant PERMIT2_PERMIT2_TYPESTRING =
        "Permit2Witness witness)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)TokenPermissions(address token,uint256 amount)Permit2Witness(uint32 expires,address localOracle,MandateOutput[] outputs)";

    /**
     * @notice Computes the permit2 witness hash.
     */
    function Permit2WitnessHash(
        StandardOrder calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PERMIT2_WITNESS_TYPE_HASH,
                order.expires,
                order.localOracle,
                MandateOutputType.hashOutputs(order.outputs)
            )
        );
    }
}
