// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct MandateOutput {
    /// @dev Oracle implementation responsible for collecting the proof from settler on output chain.
    bytes32 oracle;
    /// @dev Output Settler on the output chain responsible for settling the output payment.
    bytes32 settler;
    uint256 chainId;
    bytes32 token;
    uint256 amount;
    bytes32 recipient;
    /// @dev Data that will be delivered to recipient through the settlement callback on the output chain. Can be used
    /// to schedule additional actions.
    bytes call;
    /// @dev Additional output context for the output settlement, encoding order types or other information.
    bytes context;
}

/**
 * @notice Helper library for the Output description order type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.'
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library MandateOutputType {
    //--- Outputs Types ---//

    bytes constant MANDATE_OUTPUT_TYPE_STUB = bytes(
        "MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
    );

    bytes32 constant MANDATE_OUTPUT_TYPE_HASH = keccak256(MANDATE_OUTPUT_TYPE_STUB);

    function hashOutput(
        MandateOutput calldata output
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MANDATE_OUTPUT_TYPE_HASH,
                output.oracle,
                output.settler,
                output.chainId,
                output.token,
                output.amount,
                output.recipient,
                keccak256(output.call),
                keccak256(output.context)
            )
        );
    }

    function hashOutputs(
        MandateOutput[] calldata outputs
    ) internal pure returns (bytes32) {
        unchecked {
            bytes memory currentHash = new bytes(32 * outputs.length);
            uint256 p;
            assembly ("memory-safe") {
                p := add(currentHash, 0x20)
            }
            for (uint256 i = 0; i < outputs.length; ++i) {
                bytes32 outputHash = hashOutput(outputs[i]);
                assembly ("memory-safe") {
                    mstore(add(p, mul(i, 0x20)), outputHash)
                }
            }
            return keccak256(currentHash);
        }
    }

    // Memory copy of the above:
    function hashOutputM(
        MandateOutput memory output
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MANDATE_OUTPUT_TYPE_HASH,
                output.oracle,
                output.settler,
                output.chainId,
                output.token,
                output.amount,
                output.recipient,
                keccak256(output.call),
                keccak256(output.context)
            )
        );
    }

    function hashOutputsM(
        MandateOutput[] memory outputs
    ) internal pure returns (bytes32) {
        unchecked {
            bytes memory currentHash = new bytes(32 * outputs.length);
            uint256 p;
            assembly ("memory-safe") {
                p := add(currentHash, 0x20)
            }
            for (uint256 i = 0; i < outputs.length; ++i) {
                bytes32 outputHash = hashOutputM(outputs[i]);
                assembly ("memory-safe") {
                    mstore(add(p, mul(i, 0x20)), outputHash)
                }
            }
            return keccak256(currentHash);
        }
    }
}
