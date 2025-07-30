// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import {console} from "forge-std/Console.sol";

import { BytesLib } from "../../src/libs/BytesLib.sol";

contract BytesLibTest is Test {
    /// @notice Function for validation BytesLib.getLengthOfBytesArray
    function getLengthOfBytesArray(bytes calldata _bytes, bytes[] calldata bytesArray) pure external {
        uint256 length = BytesLib.getLengthOfBytesArray(_bytes);
        assertEq(length, bytesArray.length);
    }

    /// @notice Function for generating valid inputs to getLengthOfBytesArray
    function test_generator_getLengthOfBytesArray(bytes[] calldata bytesArray) view external {
        this.getLengthOfBytesArray(abi.encode(bytesArray), bytesArray);
    }

    /// @notice Function for validation BytesLib.getBytesOfArray
    function getBytesOfArray(bytes calldata _bytes, bytes[] calldata bytesArray) pure external {
        console.logBytes(_bytes);
        for (uint256 i; i < bytesArray.length; ++i) {
            bytes calldata bytesArraySlice = bytesArray[i];
            bytes calldata libArraySlice = BytesLib.getBytesOfArray(_bytes, i);
            assertEq(bytesArraySlice, libArraySlice);
        }
    }

    /// @notice Function for generating valid inputs to getBytesOfArray
    function test_generator_getBytesOfArray(bytes[] calldata bytesArray) view external {
        this.getBytesOfArray(abi.encode(bytesArray), bytesArray);
    }
}
