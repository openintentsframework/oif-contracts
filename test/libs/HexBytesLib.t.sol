// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { HexBytes } from "src/libs/HexBytesLib.sol";

contract HexBytesLibTest is Test {
    // Helper wrappers so we can use `vm.expectRevert` on the library calls (revert must occur in a deeper frame).
    function _call_fromHexChar(
        uint8 c
    ) external pure {
        HexBytes.fromHexChar(c);
    }

    function _call_hexBytesToBytes32(
        bytes memory input
    ) external pure {
        HexBytes.hexBytesToBytes32(input);
    }

    /*//////////////////////////////////////////////////////////////
                             fromHexChar
    //////////////////////////////////////////////////////////////*/

    function test_fromHexChar_digits() public pure {
        assertEq(HexBytes.fromHexChar(uint8(bytes1("0"))), 0);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("1"))), 1);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("2"))), 2);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("3"))), 3);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("4"))), 4);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("5"))), 5);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("6"))), 6);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("7"))), 7);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("8"))), 8);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("9"))), 9);
    }

    function test_fromHexChar_lowercase_letters() public pure {
        assertEq(HexBytes.fromHexChar(uint8(bytes1("a"))), 10);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("b"))), 11);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("c"))), 12);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("d"))), 13);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("e"))), 14);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("f"))), 15);
    }

    function test_fromHexChar_uppercase_letters() public pure {
        assertEq(HexBytes.fromHexChar(uint8(bytes1("A"))), 10);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("B"))), 11);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("C"))), 12);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("D"))), 13);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("E"))), 14);
        assertEq(HexBytes.fromHexChar(uint8(bytes1("F"))), 15);
    }

    function test_fromHexChar_invalid_reverts() public {
        vm.expectRevert(HexBytes.InvalidHexChar.selector);
        this._call_fromHexChar(uint8(bytes1("g")));

        vm.expectRevert(HexBytes.InvalidHexChar.selector);
        this._call_fromHexChar(uint8(bytes1("x")));

        vm.expectRevert(HexBytes.InvalidHexChar.selector);
        this._call_fromHexChar(uint8(bytes1(" ")));
    }

    /*//////////////////////////////////////////////////////////////
                           hexBytesToBytes32
    //////////////////////////////////////////////////////////////*/

    function test_hexBytesToBytes32_zero_no_prefix() public pure {
        bytes memory input = bytes("0000000000000000000000000000000000000000000000000000000000000000");

        bytes32 result = HexBytes.hexBytesToBytes32(input);
        assertEq(result, bytes32(0));
    }

    function test_hexBytesToBytes32_zero_with_prefix() public pure {
        bytes memory input = bytes("0x0000000000000000000000000000000000000000000000000000000000000000");

        bytes32 result = HexBytes.hexBytesToBytes32(input);
        assertEq(result, bytes32(0));
    }

    function test_hexBytesToBytes32_all_ff() public pure {
        bytes memory input = bytes("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");

        bytes32 result = HexBytes.hexBytesToBytes32(input);
        assertEq(result, bytes32(type(uint256).max));
    }

    function test_hexBytesToBytes32_all_ff_with_prefix() public pure {
        bytes memory input = bytes("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");

        bytes32 result = HexBytes.hexBytesToBytes32(input);
        assertEq(result, bytes32(type(uint256).max));
    }

    function test_hexBytesToBytes32_first_and_last_bytes_set() public pure {
        // 0x11......ff
        bytes memory input = bytes("11ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");

        bytes32 result = HexBytes.hexBytesToBytes32(input);
        assertEq(result, hex"11ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    }

    function test_hexBytesToBytes32_mixed_pattern_with_prefix() public pure {
        bytes memory input = bytes("0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");

        bytes32 result = HexBytes.hexBytesToBytes32(input);
        assertEq(result, hex"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    }

    function test_hexBytesToBytes32_invalid_length_short_reverts() public {
        // 62 hex chars instead of 64
        bytes memory input = bytes("00000000000000000000000000000000000000000000000000000000000000");

        vm.expectRevert(HexBytes.InvalidHexBytes32Length.selector);
        this._call_hexBytesToBytes32(input);
    }

    function test_hexBytesToBytes32_invalid_length_long_reverts() public {
        // 66 hex chars instead of 64
        bytes memory input = bytes("000000000000000000000000000000000000000000000000000000000000000000");

        vm.expectRevert(HexBytes.InvalidHexBytes32Length.selector);
        this._call_hexBytesToBytes32(input);
    }

    function test_hexBytesToBytes32_invalid_hex_char_reverts() public {
        // Contains 'g', which is not valid hex
        bytes memory input = bytes("gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg");

        vm.expectRevert(HexBytes.InvalidHexChar.selector);
        this._call_hexBytesToBytes32(input);
    }

    /*//////////////////////////////////////////////////////////////
                              sliceFromBytes
    //////////////////////////////////////////////////////////////*/

    function test_sliceFromBytes_basic_slice() public pure {
        bytes memory data = hex"00112233445566778899";
        bytes memory expected = hex"223344";

        bytes memory result = HexBytes.sliceFromBytes(data, 2, 3);
        assertEq(keccak256(result), keccak256(expected));
    }

    function test_sliceFromBytes_zero_length() public pure {
        bytes memory data = hex"00112233";

        bytes memory result = HexBytes.sliceFromBytes(data, 1, 0);
        assertEq(result.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                hasPrefix
    //////////////////////////////////////////////////////////////*/

    function test_hasPrefix_at_start_true() public pure {
        bytes memory subject = hex"0011223344556677";
        bytes memory prefix = hex"0011";

        bool result = HexBytes.hasPrefix(subject, prefix, 0);
        assertTrue(result);
    }

    function test_hasPrefix_at_offset_true() public pure {
        bytes memory subject = hex"0011223344556677";
        bytes memory prefix = hex"2233";

        bool result = HexBytes.hasPrefix(subject, prefix, 2);
        assertTrue(result);
    }

    function test_hasPrefix_mismatch_false() public pure {
        bytes memory subject = hex"0011223344556677";
        bytes memory prefix = hex"aabb";

        bool result = HexBytes.hasPrefix(subject, prefix, 0);
        assertFalse(result);
    }

    function test_hasPrefix_out_of_bounds_start_false() public pure {
        bytes memory subject = hex"0011223344556677";
        bytes memory prefix = hex"0011";

        bool result = HexBytes.hasPrefix(subject, prefix, 20);
        assertFalse(result);
    }

    function test_hasPrefix_prefix_runs_past_end_false() public pure {
        bytes memory subject = hex"0011223344556677";
        bytes memory prefix = hex"667788";

        bool result = HexBytes.hasPrefix(subject, prefix, 6);
        assertFalse(result);
    }
}

