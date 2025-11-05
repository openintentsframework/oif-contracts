// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputType } from "../types/MandateOutputType.sol";
import { StandardOrder, StandardOrderType } from "../types/StandardOrderType.sol";

/**
 * @notice The signed witness / mandate used for the permit2 transaction.
 * @dev The filldeadline is part of the Permit2 struct as the openDeadline.
 */
struct Permit2Witness {
    uint32 expires;
    address inputOracle;
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
        "Permit2Witness(uint32 expires,address inputOracle,uint256[2][] inputs,MandateOutput[] outputs)"
    );

    // M comes earlier than P.
    bytes constant PERMIT2_WITNESS_TYPE = abi.encodePacked(
        "Permit2Witness(uint32 expires,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)"
    );

    bytes32 constant PERMIT2_WITNESS_TYPE_HASH = keccak256(PERMIT2_WITNESS_TYPE);

    /// @notice Typestring for handed to Permit2.
    string constant PERMIT2_PERMIT2_TYPESTRING =
        "Permit2Witness witness)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)Permit2Witness(uint32 expires,address inputOracle,MandateOutput[] outputs)TokenPermissions(address token,uint256 amount)";
    /**
     * @notice Computes the permit2 witness hash.
     * @param order The Standard Order.
     * @return The permit2 witness hash.
     */

    function Permit2WitnessHash(
        StandardOrder calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PERMIT2_WITNESS_TYPE_HASH,
                order.expires,
                order.inputOracle,
                MandateOutputType.hashOutputs(order.outputs)
            )
        );
    }
}
