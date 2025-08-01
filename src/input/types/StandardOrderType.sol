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
 * @notice Helper library for the Catalyst order type.
 * TYPE_PARTIAL: An incomplete type. Is missing a field.
 * TYPE_STUB: Type has no subtypes.
 * TYPE: Is complete including sub-types.
 */
library StandardOrderType {
    using StandardOrderType for bytes;

    function orderIdentifier(
        bytes calldata order
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                block.chainid,
                address(this),
                order.user(),
                order.nonce(),
                order.expires(),
                order.fillDeadline(),
                order.inputOracle(),
                keccak256(abi.encodePacked(order.inputs())),
                abi.encode(order.outputs())
            )
        );
    }

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

    // --- Standard Order Decoding Helpers --- //

    /**
     * @notice Loads the user from an abi.encoded standard order given a bytes calldata pointer
     * @param order Bytes pointer to abiencoded standard order
     * @return _user Decoded user address for the order.
     */
    function user(
        bytes calldata order
    ) internal pure returns (address _user) {
        assembly ("memory-safe") {
            // Load the First element 1*32 with offset 12 = 0x2c
            // Clean upper 12 bytes
            _user := shr(96, calldataload(add(order.offset, 0x2c)))
        }
    }

    /**
     * @notice Loads the nonce from an abi.encoded standard order given a bytes calldata pointer
     * @param order Bytes pointer to abi encoded standard order
     * @return _nonce Decoded nonce for the order.
     */
    function nonce(
        bytes calldata order
    ) internal pure returns (uint256 _nonce) {
        assembly ("memory-safe") {
            // Load the second element 2*32 with offset 0 = 0x40
            _nonce := calldataload(add(order.offset, 0x40))
        }
    }

    /**
     * @notice Loads the originChainId from an abi.encoded standard order given a bytes calldata pointer
     * @param order Bytes pointer to abi encoded standard order
     * @return _originChainId Decoded originChainId for the order.
     */
    function originChainId(
        bytes calldata order
    ) internal pure returns (uint256 _originChainId) {
        assembly ("memory-safe") {
            // Load the third element 3*32 with offset 0 = 0x60
            _originChainId := calldataload(add(order.offset, 0x60))
        }
    }

    /**
     * @notice Loads the expiry from an abi.encoded standard order given a bytes calldata pointer
     * @param order Bytes pointer to abi encoded standard order
     * @return _expires Decoded expiry for the order.
     */
    function expires(
        bytes calldata order
    ) internal pure returns (uint32 _expires) {
        assembly ("memory-safe") {
            // Load the fourth element 4*32 with offset 28 = 0x9c
            _expires := shr(224, calldataload(add(order.offset, 0x9c)))
        }
    }

    /**
     * @notice Loads the fill deadline from an abi.encoded standard order given a bytes calldata pointer
     * @param order Bytes pointer to abi encoded standard order
     * @return _fillDeadline Decoded fill deadline for the order.
     */
    function fillDeadline(
        bytes calldata order
    ) internal pure returns (uint32 _fillDeadline) {
        assembly ("memory-safe") {
            // Load the fifth element 5*32 with offset 28 = 0xbc
            _fillDeadline := shr(224, calldataload(add(order.offset, 0xbc)))
        }
    }

    /**
     * @notice Loads the input oracle from an abi.encoded standard order given a bytes calldata pointer
     * @param order Bytes pointer to abi encoded standard order
     * @return _inputOracle Decoded input oracle for the order.
     */
    function inputOracle(
        bytes calldata order
    ) internal pure returns (address _inputOracle) {
        assembly ("memory-safe") {
            // Load the sixth element 6*32 with offset 12 = 0xcc
            _inputOracle := shr(96, calldataload(add(order.offset, 0xcc)))
        }
    }

    /**
     * @notice Loads the order inputs from an abi.encoded standard order given a bytes calldata pointer
     * @param order Bytes pointer to abi encoded standard order
     * @return _input Decoded inputs calldata pointer for the order.
     */
    function inputs(
        bytes calldata order
    ) internal pure returns (uint256[2][] calldata _input) {
        assembly ("memory-safe") {
            // Load the seventh element 7*32 with offset 0 = 0xe0
            let inputsLengthPointer := add(add(order.offset, calldataload(add(order.offset, 0xe0))), 0x20)
            _input.offset := add(inputsLengthPointer, 0x20)
            _input.length := calldataload(inputsLengthPointer)
        }
    }

    /**
     * @notice Loads the order inputs from an abi.encoded standard order given a bytes calldata pointer
     * @param order Bytes pointer to abi encoded standard order
     * @return _outputs Decoded outputs pointer for the order.
     */
    function outputs(
        bytes calldata order
    ) internal pure returns (MandateOutput[] calldata _outputs) {
        assembly ("memory-safe") {
            // Load the eighth element 8*32 with offset 0 = 0x100
            let outputsLengthPointer := add(add(order.offset, calldataload(add(order.offset, 0x100))), 0x20)
            _outputs.offset := add(outputsLengthPointer, 0x20)
            _outputs.length := calldataload(outputsLengthPointer)
        }
    }

    // --- Witness Helpers --- //

    /// @dev TheCompact needs us to provide the type without the last ")"
    bytes constant BATCH_COMPACT_SUB_TYPES = bytes(
        "uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context"
    );

    /// @dev For hashing of our subtypes, we need proper types.
    bytes constant CATALYST_WITNESS_TYPE = abi.encodePacked(
        "Mandate(uint32 fillDeadline,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
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
