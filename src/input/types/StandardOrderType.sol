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
 * @notice This is the signed Compact witness structure. This allows us to more easily collect the order hash.
 * Notice that this is different to both the order data and the ERC7683 order.
 */
struct Mandate {
    uint32 fillDeadline;
    address localOracle;
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
                order.localOracle(),
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
                order.localOracle,
                keccak256(abi.encodePacked(order.inputs)),
                abi.encode(order.outputs)
            )
        );
    }

    // --- Standard Order Decoding Helpers --- //
    // For 7683 compliance, the order will be given to us on open as a series of bytes. To aid with decoding various
    // elements of the order, the below decoding aids are provided.

    uint256 internal constant MINIMUM_STANDARD_ORDER_LENGTH = 13 * 32;

    error UndecodeableOrder(uint256 size);

    /// @notice Validates that the order has a minimum size that allows us to use pure calldata loads to decode its
    /// bytes
    function validateMinimumCalldataSize(
        bytes calldata order
    ) internal pure {
        if (order.length < MINIMUM_STANDARD_ORDER_LENGTH) revert UndecodeableOrder(order.length);
    }

    /// @dev Loads beyond its slot. bytes length needs to be validated.
    function user(
        bytes calldata order
    ) internal pure returns (address _user) {
        assembly ("memory-safe") {
            // Load the First element 1*32 with offset 12 = 0x2c
            // Clean upper 12 bytes
            _user := shr(96, calldataload(add(order.offset, 0x2c)))
        }
    }

    function nonce(
        bytes calldata order
    ) internal pure returns (uint256 _nonce) {
        assembly ("memory-safe") {
            // Load the second element 2*32 with offset 0 = 0x40
            _nonce := calldataload(add(order.offset, 0x40))
        }
    }

    function originChainId(
        bytes calldata order
    ) internal pure returns (uint256 _originChainId) {
        assembly ("memory-safe") {
            // Load the third element 3*32 with offset 0 = 0x60
            _originChainId := calldataload(add(order.offset, 0x60))
        }
    }

    /// @dev Loads beyond its slot. bytes length needs to be validated.
    function expires(
        bytes calldata order
    ) internal pure returns (uint32 _expires) {
        assembly ("memory-safe") {
            // Load the fourth element 4*32 with offset 28 = 0x9c
            _expires := shr(224, calldataload(add(order.offset, 0x9c)))
        }
    }

    function fillDeadline(
        bytes calldata order
    ) internal pure returns (uint32 _fillDeadline) {
        assembly ("memory-safe") {
            // Load the fifth element 5*32 with offset 28 = 0xbc
            _fillDeadline := shr(224, calldataload(add(order.offset, 0xbc)))
        }
    }

    function localOracle(
        bytes calldata order
    ) internal pure returns (address _localOracle) {
        assembly ("memory-safe") {
            // Load the sixth element 6*32 with offset 12 = 0xcc
            _localOracle := shr(96, calldataload(add(order.offset, 0xcc)))
        }
    }

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
        "uint32 fillDeadline,address localOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context"
    );

    /// @dev For hashing of our subtypes, we need proper types.
    bytes constant CATALYST_WITNESS_TYPE = abi.encodePacked(
        "Mandate(uint32 fillDeadline,address localOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes call,bytes context)"
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
                order.localOracle,
                MandateOutputType.hashOutputs(order.outputs)
            )
        );
    }
}
