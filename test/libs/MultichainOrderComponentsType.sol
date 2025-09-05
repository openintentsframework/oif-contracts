// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { MultichainOrderComponentType } from "../../src/input/types/MultichainOrderComponentType.sol";

contract MultichainOrderComponentTypeTest is Test {
    function constructInputHash(
        uint256 inputsChainId,
        uint256 chainIndex,
        uint256[2][] calldata inputs,
        bytes32[] calldata additionalChains
    ) external pure returns (bytes32) {
        return MultichainOrderComponentType.constructInputHash(inputsChainId, chainIndex, inputs, additionalChains);
    }

    struct SetOfInputs {
        uint256 inputsChainId;
        uint256[2][] inputs;
    }

    function discardIndex(uint256 index, bytes32[] memory arr) pure internal returns (bytes32[] memory newArr) {
        newArr = new bytes32[](arr.length - 1);
        for (uint256 i; i < arr.length; ++i) {
            if (i == index) continue;
            newArr[index < i ? i - 1 : i] = arr[i];
        }
    }
    
    /// @dev Test a documentation assertion that hashInputs is keccak256(abi.encodePacked(chainId, idsAndAmounts))
    function test_hashInputs_eq_keccak256_abi_encode(uint256 chainId, uint256[2][] calldata idsAndAmounts) external pure {
        bytes32 functionHash = MultichainOrderComponentType.hashInputs(chainId, idsAndAmounts);
        bytes32 assumedEqualTo = keccak256(abi.encodePacked(chainId, idsAndAmounts));
        assertEq(functionHash, assumedEqualTo);
    }

    /// @dev Test when we iterate over a fixed set of inputs we get the same order id for all inputs.
    function test_constructInputHash(
        SetOfInputs[] calldata orderComponents
    ) external view {
        bytes32[] memory inputComponentHashes = new bytes32[](orderComponents.length);
        for (uint256 i; i < inputComponentHashes.length; ++i) {
            inputComponentHashes[i] =
                MultichainOrderComponentType.hashInputs(orderComponents[i].inputsChainId, orderComponents[i].inputs);
        }
        vm.assume(orderComponents.length != 0);
        SetOfInputs calldata firstInputSet = orderComponents[0];
        bytes32 firstIndexHash = this.constructInputHash(
            firstInputSet.inputsChainId, 0, firstInputSet.inputs, discardIndex(0, inputComponentHashes)
        );
        for (uint256 i = 1; i < inputComponentHashes.length; ++i) {
            SetOfInputs calldata inputSet = orderComponents[i];
            bytes32 computedComponentHash = this.constructInputHash(
                inputSet.inputsChainId, i, inputSet.inputs, discardIndex(i, inputComponentHashes)
            );
            assertEq(firstIndexHash, computedComponentHash);
        }
    }
}
