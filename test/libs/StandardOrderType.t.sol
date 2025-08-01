// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { MandateOutput, StandardOrder, StandardOrderType } from "../../src/input/types/StandardOrderType.sol";

contract StandardOrderTypeTest is Test {
    using StandardOrderType for bytes;

    StandardOrder order;

    function validate(bytes calldata _bytes, bytes calldata junk) external view {
        this.validateUser(_bytes, junk);
        this.validateNonce(_bytes, junk);
        this.validateOriginChainId(_bytes, junk);
        this.validateExpires(_bytes, junk);
        this.validateFillDeadline(_bytes, junk);
        this.validateInputOracle(_bytes, junk);
        this.validateInputs(_bytes, junk);
        this.validateOutputs(_bytes, junk);
    }

    function validateUser(bytes calldata _bytes, bytes calldata) external view {
        assertEq(order.user, _bytes.user());
    }

    function validateNonce(bytes calldata _bytes, bytes calldata) external view {
        assertEq(order.nonce, _bytes.nonce());
    }

    function validateOriginChainId(bytes calldata _bytes, bytes calldata) external view {
        assertEq(order.originChainId, _bytes.originChainId());
    }

    function validateExpires(bytes calldata _bytes, bytes calldata) external view {
        assertEq(order.expires, _bytes.expires());
    }

    function validateFillDeadline(bytes calldata _bytes, bytes calldata) external view {
        assertEq(order.fillDeadline, _bytes.fillDeadline());
    }

    function validateInputOracle(bytes calldata _bytes, bytes calldata) external view {
        assertEq(order.inputOracle, _bytes.inputOracle());
    }

    function validateInputs(bytes calldata _bytes, bytes calldata) external view {
        uint256[2][] calldata inputs = _bytes.inputs();
        for (uint256 i; i < order.inputs.length; ++i) {
            uint256[2] memory input = order.inputs[i];
            uint256[2] calldata loadedInput = inputs[i];
            assertEq(bytes32(input[0]), bytes32(loadedInput[0]));
            assertEq(bytes32(input[1]), bytes32(loadedInput[1]));
        }
    }

    function validateOutputs(bytes calldata _bytes, bytes calldata) external view {
        MandateOutput[] calldata outputs = _bytes.outputs();
        for (uint256 i; i < outputs.length; ++i) {
            MandateOutput memory output = order.outputs[i];
            MandateOutput calldata loadedOutput = outputs[i];
            assertEq(abi.encode(output), abi.encode(loadedOutput));
        }
    }

    /// @notice Function for generating valid inputs to the validation functions
    function test_generator(StandardOrder calldata _order, bytes calldata junk) external {
        order = _order;
        this.validate(abi.encode(_order), junk);
    }
}
