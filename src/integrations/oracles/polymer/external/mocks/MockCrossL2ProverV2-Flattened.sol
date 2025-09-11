// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.15 ^0.8.0 ^0.8.8;

// contracts/interfaces/IClientUpdates.sol

/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

enum LightClientType {
    SimTestLightClient, // Note: not deployed on any mainnets
    OptimisticLightClient, // Our native opstack light client
    SequencerLightClient, // Our native sequencer light client, which does not check l1 origin check to cut down on
    // latency
    ReOrgResistantSequencerLightClient // Our native sequencer light client, which checks for l1 origin checks to be
        // re-org resistant

}

interface IClientUpdates {
    /**
     * @dev Adds an appHash to the internal store, after verifying the client update proof associated with the light
     * client implementation.
     * @param proof A generic byte array that contains proof data to prove the apphash client update. This can differ
     * depending on the light client type. E.g. this can be an abi.encoded struct which contains an OpL2StateProof and
     * L1Block from the IProofVerifier
     * interface.
     * @param appHash App hash (state root) to be verified
     */
    function updateClient(bytes calldata proof, uint256 height, uint256 appHash) external;

    /*
    * Returns the type of the light client, useful for relayers to know which light client implementation is at which
    address.
    */
    function LIGHT_CLIENT_TYPE() external view returns (LightClientType);
}

// contracts/interfaces/ICrossL2ProverV2.sol

/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @title ICrossL2Prover
 * @author Polymer Labs
 * @notice A contract that can prove peptides state. Since peptide is an aggregator of many chains' states, this
 * contract can in turn be used to prove any arbitrary events and/or storage on counterparty chains.
 */
interface ICrossL2ProverV2 {
    /**
     * @notice A a log at a given raw rlp encoded receipt at a given logIndex within the receipt.
     * @notice the receiptRLP should first be validated by calling validateReceipt.
     * @param proof: The proof of a given rlp bytes for the receipt, returned from the receipt MMPT of a block.
     * @return chainId The chainID that the proof proves the log for
     * @return emittingContract The address of the contract that emitted the log on the source chain
     * @return topics The topics of the event. First topic is the event signature that can be calculated by
     * Event.selector. The remaining elements in this array are the indexed parameters of the event.
     * @return unindexedData // The abi encoded non-indexed parameters of the event.
     */
    function validateEvent(bytes calldata proof)
        external
        view
        returns (uint32 chainId, address emittingContract, bytes calldata topics, bytes calldata unindexedData);

    /**
     * Return srcChain, Block Number, Receipt Index, and Local Index for a requested proof
     */
    function inspectLogIdentifier(bytes calldata proof)
        external
        pure
        returns (uint32 srcChain, uint64 blockNumber, uint16 receiptIndex, uint8 logIndex);

    /**
     * Return polymer state root, height , and signature over height and root which can be verified by
     * crypto.pubkey(keccak(peptideStateRoot, peptideHeight))
     */
    function inspectPolymerState(bytes calldata proof)
        external
        pure
        returns (bytes32 stateRoot, uint64 height, bytes memory signature);
}

// lib/openzeppelin-contracts/contracts/utils/math/Math.sol

// OpenZeppelin Contracts (last updated v4.9.0) (utils/math/Math.sol)

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    enum Rounding {
        Down, // Toward negative infinity
        Up, // Toward infinity
        Zero // Toward zero

    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds up instead
     * of rounding down.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv)
     * with further edits by Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            require(denominator > prod1, "Math: mulDiv overflow");

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator. Always
            // >= 1.
            // See https://cs.stackexchange.com/q/138556/92363.

            // Does not overflow because the denominator cannot be zero at this stage in the function.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works
            // in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (rounding == Rounding.Up && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded down.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        //
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`. This value can be written `msb(a)=2**k` with `k=log2(a)`.
        //
        // This can be rewritten `2**log2(a) <= a < 2**(log2(a) + 1)`
        // → `sqrt(2**k) <= sqrt(a) < sqrt(2**(k+1))`
        // → `2**(k/2) <= sqrt(a) < 2**((k+1)/2) <= 2**(k/2 + 1)`
        //
        // Consequently, `2**(log2(a) / 2)` is a good first approximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1 << (log2(a) >> 1);

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + (rounding == Rounding.Up && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2, rounded down, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + (rounding == Rounding.Up && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10, rounded down, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + (rounding == Rounding.Up && 10 ** result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256, rounded down, of a positive value.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 16;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 8;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 4;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 2;
            }
            if (value >> 8 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + (rounding == Rounding.Up && 1 << (result << 3) < value ? 1 : 0);
        }
    }
}

// lib/openzeppelin-contracts/contracts/utils/math/SignedMath.sol

// OpenZeppelin Contracts (last updated v4.8.0) (utils/math/SignedMath.sol)

/**
 * @dev Standard signed math utilities missing in the Solidity language.
 */
library SignedMath {
    /**
     * @dev Returns the largest of two signed numbers.
     */
    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two signed numbers.
     */
    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two signed numbers without overflow.
     * The result is rounded towards zero.
     */
    function average(int256 a, int256 b) internal pure returns (int256) {
        // Formula from the book "Hacker's Delight"
        int256 x = (a & b) + ((a ^ b) >> 1);
        return x + (int256(uint256(x) >> 255) & (a ^ b));
    }

    /**
     * @dev Returns the absolute unsigned value of a signed value.
     */
    function abs(int256 n) internal pure returns (uint256) {
        unchecked {
            // must be unchecked in order to support `n = type(int256).min`
            return uint256(n >= 0 ? n : -n);
        }
    }
}

// lib/optimism/packages/contracts-bedrock/src/libraries/Bytes.sol

/// @title Bytes
/// @notice Bytes is a library for manipulating byte arrays.
library Bytes {
    /// @custom:attribution https://github.com/GNSPS/solidity-bytes-utils
    /// @notice Slices a byte array with a given starting index and length. Returns a new byte array
    ///         as opposed to a pointer to the original array. Will throw if trying to slice more
    ///         bytes than exist in the array.
    /// @param _bytes Byte array to slice.
    /// @param _start Starting index of the slice.
    /// @param _length Length of the slice.
    /// @return Slice of the input byte array.
    function slice(bytes memory _bytes, uint256 _start, uint256 _length) internal pure returns (bytes memory) {
        unchecked {
            require(_length + 31 >= _length, "slice_overflow");
            require(_start + _length >= _start, "slice_overflow");
            require(_bytes.length >= _start + _length, "slice_outOfBounds");
        }

        bytes memory tempBytes;

        assembly {
            switch iszero(_length)
            case 0 {
                // Get a location of some free memory and store it in tempBytes as
                // Solidity does for memory variables.
                tempBytes := mload(0x40)

                // The first word of the slice result is potentially a partial
                // word read from the original array. To read it, we calculate
                // the length of that partial word and start copying that many
                // bytes into the array. The first word we copy will start with
                // data we don't care about, but the last `lengthmod` bytes will
                // land at the beginning of the contents of the new array. When
                // we're done copying, we overwrite the full first word with
                // the actual length of the slice.
                let lengthmod := and(_length, 31)

                // The multiplication in the next line is necessary
                // because when slicing multiples of 32 bytes (lengthmod == 0)
                // the following copy loop was copying the origin's length
                // and then ending prematurely not copying everything it should.
                let mc := add(add(tempBytes, lengthmod), mul(0x20, iszero(lengthmod)))
                let end := add(mc, _length)

                for {
                    // The multiplication in the next line has the same exact purpose
                    // as the one above.
                    let cc := add(add(add(_bytes, lengthmod), mul(0x20, iszero(lengthmod))), _start)
                } lt(mc, end) {
                    mc := add(mc, 0x20)
                    cc := add(cc, 0x20)
                } { mstore(mc, mload(cc)) }

                mstore(tempBytes, _length)

                //update free-memory pointer
                //allocating the array padded to 32 bytes like the compiler does now
                mstore(0x40, and(add(mc, 31), not(31)))
            }
            //if we want a zero-length slice let's just return a zero-length array
            default {
                tempBytes := mload(0x40)

                //zero out the 32 bytes slice we are about to return
                //we need to do it because Solidity does not garbage collect
                mstore(tempBytes, 0)

                mstore(0x40, add(tempBytes, 0x20))
            }
        }

        return tempBytes;
    }

    /// @notice Slices a byte array with a given starting index up to the end of the original byte
    ///         array. Returns a new array rathern than a pointer to the original.
    /// @param _bytes Byte array to slice.
    /// @param _start Starting index of the slice.
    /// @return Slice of the input byte array.
    function slice(bytes memory _bytes, uint256 _start) internal pure returns (bytes memory) {
        if (_start >= _bytes.length) {
            return bytes("");
        }
        return slice(_bytes, _start, _bytes.length - _start);
    }

    /// @notice Converts a byte array into a nibble array by splitting each byte into two nibbles.
    ///         Resulting nibble array will be exactly twice as long as the input byte array.
    /// @param _bytes Input byte array to convert.
    /// @return Resulting nibble array.
    function toNibbles(bytes memory _bytes) internal pure returns (bytes memory) {
        bytes memory _nibbles;
        assembly {
            // Grab a free memory offset for the new array
            _nibbles := mload(0x40)

            // Load the length of the passed bytes array from memory
            let bytesLength := mload(_bytes)

            // Calculate the length of the new nibble array
            // This is the length of the input array times 2
            let nibblesLength := shl(0x01, bytesLength)

            // Update the free memory pointer to allocate memory for the new array.
            // To do this, we add the length of the new array + 32 bytes for the array length
            // rounded up to the nearest 32 byte boundary to the current free memory pointer.
            mstore(0x40, add(_nibbles, and(not(0x1F), add(nibblesLength, 0x3F))))

            // Store the length of the new array in memory
            mstore(_nibbles, nibblesLength)

            // Store the memory offset of the _bytes array's contents on the stack
            let bytesStart := add(_bytes, 0x20)

            // Store the memory offset of the nibbles array's contents on the stack
            let nibblesStart := add(_nibbles, 0x20)

            // Loop through each byte in the input array
            for { let i := 0x00 } lt(i, bytesLength) { i := add(i, 0x01) } {
                // Get the starting offset of the next 2 bytes in the nibbles array
                let offset := add(nibblesStart, shl(0x01, i))
                // Load the byte at the current index within the `_bytes` array
                let b := byte(0x00, mload(add(bytesStart, i)))

                // Pull out the first nibble and store it in the new array
                mstore8(offset, shr(0x04, b))
                // Pull out the second nibble and store it in the new array
                mstore8(add(offset, 0x01), and(b, 0x0F))
            }
        }
        return _nibbles;
    }

    /// @notice Compares two byte arrays by comparing their keccak256 hashes.
    /// @param _bytes First byte array to compare.
    /// @param _other Second byte array to compare.
    /// @return True if the two byte arrays are equal, false otherwise.
    function equal(bytes memory _bytes, bytes memory _other) internal pure returns (bool) {
        return keccak256(_bytes) == keccak256(_other);
    }
}

// lib/optimism/packages/contracts-bedrock/src/libraries/rlp/RLPReader.sol

/// @custom:attribution https://github.com/hamdiallam/Solidity-RLP
/// @title RLPReader
/// @notice RLPReader is a library for parsing RLP-encoded byte arrays into Solidity types. Adapted
///         from Solidity-RLP (https://github.com/hamdiallam/Solidity-RLP) by Hamdi Allam with
///         various tweaks to improve readability.
library RLPReader {
    /// @notice Custom pointer type to avoid confusion between pointers and uint256s.
    type MemoryPointer is uint256;

    /// @notice RLP item types.
    /// @custom:value DATA_ITEM Represents an RLP data item (NOT a list).
    /// @custom:value LIST_ITEM Represents an RLP list item.
    enum RLPItemType {
        DATA_ITEM,
        LIST_ITEM
    }

    /// @notice Struct representing an RLP item.
    /// @custom:field length Length of the RLP item.
    /// @custom:field ptr    Pointer to the RLP item in memory.
    struct RLPItem {
        uint256 length;
        MemoryPointer ptr;
    }

    /// @notice Max list length that this library will accept.
    uint256 internal constant MAX_LIST_LENGTH = 32;

    /// @notice Converts bytes to a reference to memory position and length.
    /// @param _in Input bytes to convert.
    /// @return out_ Output memory reference.
    function toRLPItem(bytes memory _in) internal pure returns (RLPItem memory out_) {
        // Empty arrays are not RLP items.
        require(_in.length > 0, "RLPReader: length of an RLP item must be greater than zero to be decodable");

        MemoryPointer ptr;
        assembly {
            ptr := add(_in, 32)
        }

        out_ = RLPItem({length: _in.length, ptr: ptr});
    }

    /// @notice Reads an RLP list value into a list of RLP items.
    /// @param _in RLP list value.
    /// @return out_ Decoded RLP list items.
    function readList(RLPItem memory _in) internal pure returns (RLPItem[] memory out_) {
        (uint256 listOffset, uint256 listLength, RLPItemType itemType) = _decodeLength(_in);

        require(itemType == RLPItemType.LIST_ITEM, "RLPReader: decoded item type for list is not a list item");

        require(listOffset + listLength == _in.length, "RLPReader: list item has an invalid data remainder");

        // Solidity in-memory arrays can't be increased in size, but *can* be decreased in size by
        // writing to the length. Since we can't know the number of RLP items without looping over
        // the entire input, we'd have to loop twice to accurately size this array. It's easier to
        // simply set a reasonable maximum list length and decrease the size before we finish.
        out_ = new RLPItem[](MAX_LIST_LENGTH);

        uint256 itemCount = 0;
        uint256 offset = listOffset;
        while (offset < _in.length) {
            (uint256 itemOffset, uint256 itemLength,) = _decodeLength(
                RLPItem({length: _in.length - offset, ptr: MemoryPointer.wrap(MemoryPointer.unwrap(_in.ptr) + offset)})
            );

            // We don't need to check itemCount < out.length explicitly because Solidity already
            // handles this check on our behalf, we'd just be wasting gas.
            out_[itemCount] = RLPItem({
                length: itemLength + itemOffset,
                ptr: MemoryPointer.wrap(MemoryPointer.unwrap(_in.ptr) + offset)
            });

            itemCount += 1;
            offset += itemOffset + itemLength;
        }

        // Decrease the array size to match the actual item count.
        assembly {
            mstore(out_, itemCount)
        }
    }

    /// @notice Reads an RLP list value into a list of RLP items.
    /// @param _in RLP list value.
    /// @return out_ Decoded RLP list items.
    function readList(bytes memory _in) internal pure returns (RLPItem[] memory out_) {
        out_ = readList(toRLPItem(_in));
    }

    /// @notice Reads an RLP bytes value into bytes.
    /// @param _in RLP bytes value.
    /// @return out_ Decoded bytes.
    function readBytes(RLPItem memory _in) internal pure returns (bytes memory out_) {
        (uint256 itemOffset, uint256 itemLength, RLPItemType itemType) = _decodeLength(_in);

        require(itemType == RLPItemType.DATA_ITEM, "RLPReader: decoded item type for bytes is not a data item");

        require(_in.length == itemOffset + itemLength, "RLPReader: bytes value contains an invalid remainder");

        out_ = _copy(_in.ptr, itemOffset, itemLength);
    }

    /// @notice Reads an RLP bytes value into bytes.
    /// @param _in RLP bytes value.
    /// @return out_ Decoded bytes.
    function readBytes(bytes memory _in) internal pure returns (bytes memory out_) {
        out_ = readBytes(toRLPItem(_in));
    }

    /// @notice Reads the raw bytes of an RLP item.
    /// @param _in RLP item to read.
    /// @return out_ Raw RLP bytes.
    function readRawBytes(RLPItem memory _in) internal pure returns (bytes memory out_) {
        out_ = _copy(_in.ptr, 0, _in.length);
    }

    /// @notice Decodes the length of an RLP item.
    /// @param _in RLP item to decode.
    /// @return offset_ Offset of the encoded data.
    /// @return length_ Length of the encoded data.
    /// @return type_ RLP item type (LIST_ITEM or DATA_ITEM).
    function _decodeLength(RLPItem memory _in)
        private
        pure
        returns (uint256 offset_, uint256 length_, RLPItemType type_)
    {
        // Short-circuit if there's nothing to decode, note that we perform this check when
        // the user creates an RLP item via toRLPItem, but it's always possible for them to bypass
        // that function and create an RLP item directly. So we need to check this anyway.
        require(_in.length > 0, "RLPReader: length of an RLP item must be greater than zero to be decodable");

        MemoryPointer ptr = _in.ptr;
        uint256 prefix;
        assembly {
            prefix := byte(0, mload(ptr))
        }

        if (prefix <= 0x7f) {
            // Single byte.
            return (0, 1, RLPItemType.DATA_ITEM);
        } else if (prefix <= 0xb7) {
            // Short string.

            // slither-disable-next-line variable-scope
            uint256 strLen = prefix - 0x80;

            require(
                _in.length > strLen, "RLPReader: length of content must be greater than string length (short string)"
            );

            bytes1 firstByteOfContent;
            assembly {
                firstByteOfContent := and(mload(add(ptr, 1)), shl(248, 0xff))
            }

            require(
                strLen != 1 || firstByteOfContent >= 0x80,
                "RLPReader: invalid prefix, single byte < 0x80 are not prefixed (short string)"
            );

            return (1, strLen, RLPItemType.DATA_ITEM);
        } else if (prefix <= 0xbf) {
            // Long string.
            uint256 lenOfStrLen = prefix - 0xb7;

            require(
                _in.length > lenOfStrLen,
                "RLPReader: length of content must be > than length of string length (long string)"
            );

            bytes1 firstByteOfContent;
            assembly {
                firstByteOfContent := and(mload(add(ptr, 1)), shl(248, 0xff))
            }

            require(
                firstByteOfContent != 0x00, "RLPReader: length of content must not have any leading zeros (long string)"
            );

            uint256 strLen;
            assembly {
                strLen := shr(sub(256, mul(8, lenOfStrLen)), mload(add(ptr, 1)))
            }

            require(strLen > 55, "RLPReader: length of content must be greater than 55 bytes (long string)");

            require(
                _in.length > lenOfStrLen + strLen,
                "RLPReader: length of content must be greater than total length (long string)"
            );

            return (1 + lenOfStrLen, strLen, RLPItemType.DATA_ITEM);
        } else if (prefix <= 0xf7) {
            // Short list.
            // slither-disable-next-line variable-scope
            uint256 listLen = prefix - 0xc0;

            require(_in.length > listLen, "RLPReader: length of content must be greater than list length (short list)");

            return (1, listLen, RLPItemType.LIST_ITEM);
        } else {
            // Long list.
            uint256 lenOfListLen = prefix - 0xf7;

            require(
                _in.length > lenOfListLen,
                "RLPReader: length of content must be > than length of list length (long list)"
            );

            bytes1 firstByteOfContent;
            assembly {
                firstByteOfContent := and(mload(add(ptr, 1)), shl(248, 0xff))
            }

            require(
                firstByteOfContent != 0x00, "RLPReader: length of content must not have any leading zeros (long list)"
            );

            uint256 listLen;
            assembly {
                listLen := shr(sub(256, mul(8, lenOfListLen)), mload(add(ptr, 1)))
            }

            require(listLen > 55, "RLPReader: length of content must be greater than 55 bytes (long list)");

            require(
                _in.length > lenOfListLen + listLen,
                "RLPReader: length of content must be greater than total length (long list)"
            );

            return (1 + lenOfListLen, listLen, RLPItemType.LIST_ITEM);
        }
    }

    /// @notice Copies the bytes from a memory location.
    /// @param _src    Pointer to the location to read from.
    /// @param _offset Offset to start reading from.
    /// @param _length Number of bytes to read.
    /// @return out_ Copied bytes.
    function _copy(MemoryPointer _src, uint256 _offset, uint256 _length) private pure returns (bytes memory out_) {
        out_ = new bytes(_length);
        if (_length == 0) {
            return out_;
        }

        // Mostly based on Solidity's copy_memory_to_memory:
        // solhint-disable max-line-length
        // https://github.com/ethereum/solidity/blob/34dd30d71b4da730488be72ff6af7083cf2a91f6/libsolidity/codegen/YulUtilFunctions.cpp#L102-L114
        uint256 src = MemoryPointer.unwrap(_src) + _offset;
        assembly {
            let dest := add(out_, 32)
            let i := 0
            for {} lt(i, _length) { i := add(i, 32) } { mstore(add(dest, i), mload(add(src, i))) }

            if gt(i, _length) { mstore(add(dest, _length), 0) }
        }
    }
}

// contracts/libs/ReceiptParser.sol

/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// OpIcs23ProofPath represents a commitment path in an ICS23 proof, which consists of a commitment prefix and a suffix.
struct OpIcs23ProofPath {
    bytes prefix;
    bytes suffix;
}

// OpIcs23Proof represents an ICS23 proof
struct OpIcs23Proof {
    OpIcs23ProofPath[] path;
    bytes key;
    bytes value;
    bytes prefix;
}

// the Ics23 proof related structs are used to do membership verification. These are not the actual Ics23
// format but a "solidity friendly" version of it - data is the same just packaged differently
struct Ics23Proof {
    OpIcs23Proof[] proof;
    uint256 height;
}

// This is the proof we use to verify the apphash (state) updates.
struct OpL2StateProof {
    bytes[] accountProof;
    bytes[] outputRootProof;
    bytes32 l2OutputProposalKey;
    bytes32 l2BlockHash;
}

/**
 * A library for helpers for proving peptide state
 */
library ReceiptParser {
    error invalidAddressBytes();

    function toStr(uint256 _number) public pure returns (string memory outStr) {
        if (_number == 0) {
            return "0";
        }

        uint256 length;
        uint256 number = _number;

        // Determine the length of the string
        while (number != 0) {
            length++;
            number /= 10;
        }

        bytes memory buffer = new bytes(length);

        // Convert each digit to its ASCII representation
        for (uint256 i = length; i > 0; i--) {
            buffer[i - 1] = bytes1(uint8(48 + (_number % 10)));
            _number /= 10;
        }

        outStr = string(buffer);
    }

    function bytesToAddr(bytes memory a) public pure returns (address addr) {
        if (a.length != 20) {
            revert invalidAddressBytes();
        }
        assembly {
            addr := mload(add(a, 20))
        }
    }

    function parseLog(uint256 logIndex, bytes memory receiptRLP)
        internal
        pure
        returns (address emittingContract, bytes[] memory topics, bytes memory unindexedData)
    {
        // The first byte is a RLP encoded receipt type so slice it off.
        uint8 typeByte;
        assembly {
            typeByte := byte(0, mload(add(receiptRLP, 32)))
        }
        if (typeByte < 0x80) {
            // Typed receipt: strip the type byte
            receiptRLP = Bytes.slice(receiptRLP, 1, receiptRLP.length - 1);
        }

        RLPReader.RLPItem[] memory receipt = RLPReader.readList(receiptRLP);
        /*
            // RLP encoded receipt has the following structure. Logs are the 4th RLP list item.
            type ReceiptRLP struct {
                    PostStateOrStatus []byte
                   CumulativeGasUsed uint64
                    Bloom             Bloom
                    Logs              []*Log
            }
        */

        // Each log itself is an rlp encoded datatype of 3 properties:
        // type Log struct {
        //         senderAddress bytes // contract address where this log was emitted from
        //         topics bytes        // Array of indexed topics. The first element is the 32-byte selector of the
        // event (can use TransmitToHouston.selector), and the following  elements in this array are the abi encoded
        // arguments individually
        //         topics data         // abi encoded raw bytes of unindexed data
        // }
        RLPReader.RLPItem[] memory log = RLPReader.readList(RLPReader.readList(receipt[3])[logIndex]);

        emittingContract = bytesToAddr(RLPReader.readBytes(log[0]));

        RLPReader.RLPItem[] memory encodedTopics = RLPReader.readList(log[1]);
        unindexedData = (RLPReader.readBytes(log[2])); // This is the raw unindexed data. in this case it's
        // just an abi encoded uint64

        topics = new bytes[](encodedTopics.length);
        for (uint256 i = 0; i < encodedTopics.length; i++) {
            topics[i] = RLPReader.readBytes(encodedTopics[i]);
        }
    }

    function receiptRootKey(string memory chainId, string memory clientType, uint256 height)
        internal
        pure
        returns (bytes memory proofKey)
    {
        proofKey = abi.encodePacked("chain/", chainId, "/storedReceipts/", clientType, "/receiptRoot/", toStr(height));
    }

    function eventRootKey(uint32 chainId, string memory clientType, uint256 height, uint16 receiptIndex, uint8 logIndex)
        internal
        pure
        returns (bytes memory proofKey)
    {
        // TODO actually change this to the decided structure
        return abi.encodePacked(
            "chain/",
            toStr(uint256(chainId)),
            "/storedLogs/",
            clientType,
            "/",
            toStr(height),
            "/",
            toStr(receiptIndex),
            "/",
            toStr(logIndex)
        );
    }
}

// lib/openzeppelin-contracts/contracts/utils/Strings.sol

// OpenZeppelin Contracts (last updated v4.9.0) (utils/Strings.sol)

/**
 * @dev String operations.
 */
library Strings {
    bytes16 private constant _SYMBOLS = "0123456789abcdef";
    uint8 private constant _ADDRESS_LENGTH = 20;

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        unchecked {
            uint256 length = Math.log10(value) + 1;
            string memory buffer = new string(length);
            uint256 ptr;
            /// @solidity memory-safe-assembly
            assembly {
                ptr := add(buffer, add(32, length))
            }
            while (true) {
                ptr--;
                /// @solidity memory-safe-assembly
                assembly {
                    mstore8(ptr, byte(mod(value, 10), _SYMBOLS))
                }
                value /= 10;
                if (value == 0) break;
            }
            return buffer;
        }
    }

    /**
     * @dev Converts a `int256` to its ASCII `string` decimal representation.
     */
    function toString(int256 value) internal pure returns (string memory) {
        return string(abi.encodePacked(value < 0 ? "-" : "", toString(SignedMath.abs(value))));
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        unchecked {
            return toHexString(value, Math.log256(value) + 1);
        }
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }

    /**
     * @dev Converts an `address` with fixed length of 20 bytes to its not checksummed ASCII `string` hexadecimal
     * representation.
     */
    function toHexString(address addr) internal pure returns (string memory) {
        return toHexString(uint256(uint160(addr)), _ADDRESS_LENGTH);
    }

    /**
     * @dev Returns true if the two strings are equal.
     */
    function equal(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

// lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol

// OpenZeppelin Contracts (last updated v4.9.0) (utils/cryptography/ECDSA.sol)

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS,
        InvalidSignatureV // Deprecated in v4.8

    }

    function _throwError(RecoverError error) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert("ECDSA: invalid signature");
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert("ECDSA: invalid signature length");
        } else if (error == RecoverError.InvalidSignatureS) {
            revert("ECDSA: invalid signature 's' value");
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature` or error string. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     *
     * _Available since v4.3._
     */
    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address, RecoverError) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            /// @solidity memory-safe-assembly
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength);
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, signature);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[EIP-2098 short signatures]
     *
     * _Available since v4.3._
     */
    function tryRecover(bytes32 hash, bytes32 r, bytes32 vs) internal pure returns (address, RecoverError) {
        bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        uint8 v = uint8((uint256(vs) >> 255) + 27);
        return tryRecover(hash, v, r, s);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     *
     * _Available since v4.2._
     */
    function recover(bytes32 hash, bytes32 r, bytes32 vs) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, r, vs);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     *
     * _Available since v4.3._
     */
    function tryRecover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address, RecoverError) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature);
        }

        return (signer, RecoverError.NoError);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, v, r, s);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from a `hash`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32 message) {
        // 32 is the length in bytes of hash,
        // enforced by the type signature above
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, "\x19Ethereum Signed Message:\n32")
            mstore(0x1c, hash)
            message := keccak256(0x00, 0x3c)
        }
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from `s`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes memory s) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", Strings.toString(s.length), s));
    }

    /**
     * @dev Returns an Ethereum Signed Typed Data, created from a
     * `domainSeparator` and a `structHash`. This produces hash corresponding
     * to the one signed with the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`]
     * JSON-RPC method as part of EIP-712.
     *
     * See {recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32 data) {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, "\x19\x01")
            mstore(add(ptr, 0x02), domainSeparator)
            mstore(add(ptr, 0x22), structHash)
            data := keccak256(ptr, 0x42)
        }
    }

    /**
     * @dev Returns an Ethereum Signed Data with intended validator, created from a
     * `validator` and `data` according to the version 0 of EIP-191.
     *
     * See {recover}.
     */
    function toDataWithIntendedValidatorHash(address validator, bytes memory data) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x00", validator, data));
    }
}

// contracts/core/SequencerSignatureVerifierV2.sol

/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @title SequencerSignatureVerifierV2
 * @notice Verifies ECDSA signatures from a sequencer for client updates. Is used by the SequencerSoloClient to verify
 * signatures on client updates.
 * @author Polymer Labs
 */
contract SequencerSignatureVerifierV2 {
    address public immutable SEQUENCER; // The trusted sequencer address that polymer p2p signer holds the private key
        // to
    bytes32 public immutable CHAIN_ID; // Chain ID of the L2 chain for which the sequencer signs over

    error InvalidSequencerSignature();

    constructor(address sequencer_, bytes32 chainId_) {
        SEQUENCER = sequencer_;
        CHAIN_ID = chainId_;
    }

    /**
     * @notice Verify peptide sequencer signature over a given apphash
     */
    function _verifySequencerSignature(bytes32 appHash, uint64 peptideHeight, uint8 v, bytes32 r, bytes32 s)
        internal
        view
    {
        if (
            ECDSA.recover(
                keccak256(bytes.concat(bytes32(0), CHAIN_ID, keccak256(abi.encodePacked(appHash, peptideHeight)))),
                bytes(abi.encodePacked(r, s, v))
            ) != SEQUENCER
        ) {
            revert InvalidSequencerSignature();
        }
    }
}

// contracts/core/CrossL2ProverV2.sol

/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

contract CrossL2ProverV2 is SequencerSignatureVerifierV2, ICrossL2ProverV2 {
    LightClientType public constant LIGHT_CLIENT_TYPE = LightClientType.SequencerLightClient; // Stored as a constant
        // for cheap on-chain use

    string public clientType;

    error InvalidProofKey();
    error InvalidProofValue();
    error InvalidProofRoot();

    constructor(string memory clientType_, address sequencer_, bytes32 chainId_)
        SequencerSignatureVerifierV2(sequencer_, chainId_)
    {
        clientType = clientType_;
    }
    //  +--------------------------------------------------+
    //  |  state root (32 bytes)                           | 0:32
    //  +--------------------------------------------------+
    //  |  signature (65 bytes)                            | 32:97
    //  +--------------------------------------------------+
    //  |  source chain ID (big endian, 4 bytes)           | 97:101
    //  +--------------------------------------------------+
    //  |  peptide height (big endian, 8 bytes)            | 101:109
    //  +--------------------------------------------------+
    //  |  source chain block height (big endian, 8 bytes) | 109:117
    //  +--------------------------------------------------+
    //  |  receipt index (big endian, 2 bytes)             | 117:119
    //  +--------------------------------------------------+
    //  |  event index (1 byte)                            | 119
    //  +--------------------------------------------------+
    //  |  number of topics (1 byte)                       | 120
    //  +--------------------------------------------------+
    //  |  event data end (big endian, 2 bytes)            | 121:123
    //  +--------------------------------------------------+
    //  |  event emitter (contract address) (20 bytes)     | 123:143
    //  +--------------------------------------------------+
    //  |  topics (32 bytes * number of topics)            | 143 + 32 * number of topics: eventDatEnd
    //  +--------------------------------------------------+
    //  |  event data (x bytes)                            | eventDataEnd:
    //  +--------------------------------------------------+
    //  |  iavl proof (x bytes)                            |
    //  +--------------------------------------------------+

    function validateEvent(bytes calldata proof)
        external
        view
        virtual
        returns (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData)
    {
        chainId = uint32(bytes4(proof[97:101]));
        _verifySequencerSignature(
            bytes32(proof[:32]),
            uint64(bytes8(proof[101:109])),
            uint8(proof[96]),
            bytes32(proof[32:64]),
            bytes32(proof[64:96])
        );

        uint256 eventEnd = uint16(bytes2(proof[121:123]));
        bytes memory rawEvent = proof[123:eventEnd];
        this.verifyMembership(
            bytes32(proof[:32]),
            ReceiptParser.eventRootKey(
                chainId, clientType, uint64(bytes8(proof[109:117])), uint16(bytes2(proof[117:119])), uint8(proof[119])
            ),
            keccak256(rawEvent),
            proof[eventEnd:]
        );

        (emittingContract, topics, unindexedData) = this.parseEvent(rawEvent, uint8(proof[120]));
    }

    function inspectLogIdentifier(bytes calldata proof)
        external
        pure
        virtual
        returns (uint32 srcChain, uint64 blockNumber, uint16 receiptIndex, uint8 logIndex)
    {
        return (
            uint32(bytes4(proof[97:101])),
            uint64(bytes8(proof[109:117])),
            uint16(bytes2(proof[117:119])),
            uint8(proof[119])
        );
    }

    function inspectPolymerState(bytes calldata proof)
        external
        pure
        virtual
        returns (bytes32 stateRoot, uint64 height, bytes calldata signature)
    {
        return (bytes32(proof[:32]), uint64(bytes8(proof[101:109])), proof[32:97]);
    }

    /*
    header: key start (abs) (2B), key end (abs) (2B), value start (abs) (2B), value end (abs) (2B), num paths (1B),
    layer-0: prefix, varint(key.length), key, varint(hash(value).length), hash(value)
    path-n: [header: suffix start (rel) (1B), suffix end (rel) (1B)],  path[n].prefix, path[n].suffix
    */
    function verifyMembership(bytes32 root, bytes memory key, bytes32 value, bytes calldata proof)
        public
        pure
        virtual
    {
        uint256 path0start = uint256(uint8(proof[1]));
        bytes32 prehash = sha256(abi.encodePacked(proof[2:path0start], key, hex"20", sha256(abi.encodePacked(value))));
        uint256 offset = path0start;

        for (uint256 i = 0; i < uint256(uint8(proof[0])); i++) {
            uint256 suffixstart = uint256(uint8(proof[offset]));
            uint256 suffixend = uint256(uint8(proof[offset + 1]));

            // add +2 to account for path header
            prehash = sha256(
                abi.encodePacked(
                    proof[offset + 2:offset + suffixstart], prehash, proof[offset + suffixstart:offset + suffixend]
                )
            );

            offset = offset + suffixend;
        }

        if (prehash != root) revert InvalidProofRoot();
    }

    function parseEvent(bytes calldata rawEvent, uint8 numTopics)
        public
        pure
        virtual
        returns (address emittingContract, bytes memory topics, bytes memory unindexedData)
    {
        uint256 topicsEnd = 32 * numTopics + 20;
        return (address(bytes20(rawEvent[:20])), rawEvent[20:topicsEnd], rawEvent[topicsEnd:]);
    }
}

// contracts/mocks/MockCrossL2ProverV2.sol

/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

contract MockCrossL2ProverV2 is CrossL2ProverV2 {
    // Event for proof generation
    event ProofGenerated(bytes proof);

    constructor(string memory clientType_, address sequencer_, bytes32 chainId_)
        CrossL2ProverV2(clientType_, sequencer_, chainId_)
    {}

    /**
     * @dev Generates a mock proof and emits it for local testing.
     * @param chainId_ Source chain ID.
     * @param emitter Address of the emitting contract.
     * @param topics Array of topic hashes (32 bytes each).
     * @param data Unindexed event data.
     * @return Mock proof bytes.
     */
    function generateAndEmitProof(uint32 chainId_, address emitter, bytes32[] memory topics, bytes memory data)
        external
        returns (bytes memory)
    {
        require(topics.length > 0, "At least one topic (event signature) required");

        bytes memory proof = generateMockProof(chainId_, uint8(topics.length), emitter, topics, data);

        emit ProofGenerated(proof);
        return proof;
    }

    /**
     * @dev Generates a mock proof and sends it to a validator contract.
     * @param chainId_ Source chain ID.
     * @param emitter Address of the emitting contract.
     * @param topics Array of topic hashes (32 bytes each).
     * @param data Unindexed event data.
     * @param validatorContract Address of the contract to validate the proof.
     * @return Mock proof bytes.
     */
    function generateAndSendProof(
        uint32 chainId_,
        address emitter,
        bytes32[] memory topics,
        bytes memory data,
        address validatorContract
    ) external returns (bytes memory) {
        require(topics.length > 0, "At least one topic (event signature) required");
        require(validatorContract != address(0), "Invalid validator contract address");

        bytes memory proof = generateMockProof(chainId_, uint8(topics.length), emitter, topics, data);

        // Call the validator contract's validateEvent function
        (bool success,) = validatorContract.call(abi.encodeWithSignature("validateEvent(bytes)", proof));
        require(success, "Validation call failed");

        return proof;
    }

    /**
     * @dev Modified validateEvent for testing. Skips signature and membership verification
     * to focus on proof structure and event parsing.
     */
    function validateEvent(bytes calldata proof)
        external
        view
        override
        returns (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData)
    {
        // Extract chainId from proof[97:101]
        chainId = uint32(bytes4(proof[97:101]));

        // Skip sequencer signature verification (normally done with _verifySequencerSignature)
        // In production, this ensures the proof is signed by the sequencer, but for testing,
        // we assume a valid signature.

        // Calculate event end from proof[121:123]
        uint256 eventEnd = uint256(uint16(bytes2(proof[121:123])));
        require(eventEnd <= proof.length, "Event end exceeds proof length");
        bytes memory rawEvent = proof[123:eventEnd];

        // Skip IAVL proof verification (normally done with verifyMembership)
        // In production, this checks the event's inclusion in the state root, but for testing,
        // we assume membership is valid.

        // Parse the event data
        (emittingContract, topics, unindexedData) = this.parseEvent(rawEvent, uint8(proof[120]));
    }

    /**
     * @dev Helper function to generate a mock proof for testing.
     * @param chainId_ Source chain ID.
     * @param numTopics Number of topics in the event.
     * @param emitter Address of the emitting contract.
     * @param topics_ Array of topic hashes (32 bytes each).
     * @param unindexedData_ Unindexed event data.
     * @return Mock proof bytes.
     */
    function generateMockProof(
        uint32 chainId_,
        uint8 numTopics,
        address emitter,
        bytes32[] memory topics_,
        bytes memory unindexedData_
    ) public pure returns (bytes memory) {
        require(topics_.length == numTopics, "Topics length mismatch");

        // Calculate lengths
        uint256 topicsLength = numTopics * 32;
        uint256 eventLength = 20 + topicsLength + unindexedData_.length; // emitter + topics + data
        uint256 eventEnd = 123 + eventLength; // Offset after fixed fields

        // Assemble proof
        bytes memory proof = new bytes(eventEnd + 32); // Add 32 bytes for dummy iavlProof

        // Leave fixed fields with dummy or specified values
        // - stateRoot (32 bytes): dummy
        // - signature (65 bytes): dummy
        // Values are 0 so we don't have to set them here

        // populate given chainId (4 bytes)
        bytes4 chainIdBytes = bytes4(chainId_);
        for (uint256 i = 0; i < 4; i++) {
            proof[97 + i] = chainIdBytes[i];
        }
        // peptideHeight (proof[101:109]) dummy value of 100
        proof[108] = bytes1(uint8(100));

        // blockHeight (proof[109:117]) dummy value of 200
        proof[116] = bytes1(uint8(200));

        // - receiptIndex proof[117-118] dummy avlue of 1
        proof[118] = bytes1(uint8(1));
        // eventIndex proof[119]: dummy  value of 0
        proof[119] = bytes1(0);
        // numTopics proof[120]  dummy value of num topics
        proof[120] = bytes1(numTopics);

        // eventDataEnd (2 bytes)
        bytes2 eventEndBytes = bytes2(uint16(eventEnd));
        proof[121] = eventEndBytes[0];
        proof[122] = eventEndBytes[1];

        // Event data: emitter (20 bytes) + topics + unindexedData
        bytes20 emitterBytes = bytes20(emitter);
        for (uint256 i = 0; i < 20; i++) {
            proof[123 + i] = emitterBytes[i];
        }
        for (uint256 i = 0; i < numTopics; i++) {
            bytes32 topic = topics_[i];
            for (uint256 j = 0; j < 32; j++) {
                proof[143 + i * 32 + j] = topic[j];
            }
        }
        for (uint256 i = 0; i < unindexedData_.length; i++) {
            proof[143 + topicsLength + i] = unindexedData_[i];
        }

        // iavlProof (dummy, 32 bytes)
        for (uint256 i = eventEnd; i < proof.length; i++) {
            proof[i] = bytes1(0);
        }

        return proof;
    }
}
