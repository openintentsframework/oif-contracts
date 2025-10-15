// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { BytesLib } from "../../src/libs/BytesLib.sol";

contract BytesLibTest is Test {
    /// @notice Function for validation BytesLib.getLengthOfBytesArray
    function getLengthOfBytesArray(
        bytes calldata _bytes,
        bytes[] calldata bytesArray
    ) external pure {
        uint256 length = BytesLib.getLengthOfBytesArray(_bytes);
        assertEq(length, bytesArray.length);
    }

    /// @notice Function for generating valid inputs to getLengthOfBytesArray
    function test_generator_getLengthOfBytesArray(
        bytes[] calldata bytesArray
    ) external view {
        this.getLengthOfBytesArray(abi.encode(bytesArray), bytesArray);
    }

    /// @notice Function for validation BytesLib.getBytesOfArray
    function getBytesOfArray(
        bytes calldata _bytes,
        bytes[] calldata bytesArray
    ) external pure {
        for (uint256 i; i < bytesArray.length; ++i) {
            bytes calldata bytesArraySlice = bytesArray[i];
            bytes calldata libArraySlice = BytesLib.getBytesOfArray(_bytes, i);
            assertEq(bytesArraySlice, libArraySlice);
        }
    }

    /// @notice Function for generating valid inputs to getBytesOfArray
    function test_generator_getBytesOfArray(
        bytes[] calldata bytesArray
    ) external view {
        this.getBytesOfArray(abi.encode(bytesArray), bytesArray);
    }
}
