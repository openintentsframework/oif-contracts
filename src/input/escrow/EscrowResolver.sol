// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";

import { Action, Constraint, Formula, IOrderResolver, Leg, ResolvedOrder, Step } from "../../interfaces/erc7683-v1.sol";

import { LibAddress } from "../../libs/LibAddress.sol";
import { MandateOutput } from "../types/MandateOutputType.sol";

import { StandardOrder, StandardOrderType } from "../types/StandardOrderType.sol";

import { OutputSettlerBase } from "../../output/OutputSettlerBase.sol";

interface OpenInterface {
    function openFor(bytes calldata order, address sponsor, bytes calldata signature) external;
}

contract EscrowResolver is IOrderResolver {
    using LibAddress for uint256;
    using LibAddress for address;

    function fastBytesCompare(bytes memory a, bytes memory b, bytes32 hashedB) internal pure returns (bool) {
        if (a.length != b.length) return false;
        if (a.length == 32) return bytes32(a) == bytes32(b);
        return keccak256(a) == hashedB;
    }

    function contains(bytes[] memory arr, bytes memory element) internal pure returns (bool) {
        bytes32 hashedElement = keccak256(element);
        for (uint256 i; i < arr.length; ++i) {
            if (fastBytesCompare(arr[i], element, hashedElement)) return true;
        }
        return false;
    }

    function shrink(
        bytes[] memory arr
    ) internal pure returns (bytes[] memory smallestArr) {
        if (arr.length == 0) return arr;
        bytes[] memory observed = new bytes[](arr.length);
        observed[0] = arr[0];
        uint256 numHits = 1;
        for (uint256 i = 1; i < arr.length; ++i) {
            if (contains(observed, arr[i])) continue;
            observed[numHits] = arr[i];
            unchecked {
                ++numHits;
            }
        }
        smallestArr = new bytes[](numHits);
        for (uint256 i = 0; i < numHits; ++i) {
            smallestArr[i] = observed[i];
        }
    }

    // TODO: interoperable addresses format encoding.
    function interoperableAddress(uint256 chainId, bytes32 addr) internal pure returns (bytes memory) {
        return abi.encodePacked(chainId, addr);
    }

    function hasBeenOpened(
        StandardOrder memory order
    ) internal view returns (bool) { }

    function getInitStep(
        Step[] memory steps,
        bool opened,
        bytes calldata payload,
        StandardOrder memory order
    ) internal view returns (uint256 stepIndex) {
        if (!opened) {
            bytes memory target = interoperableAddress(block.chainid, address(this).toIdentifier());
            uint256[] memory variables = new uint256[](2);
            variables[0] = 0; // address sponsor
            variables[1] = 1; // bytes sponsorSignature
            bytes memory openForAction =
                abi.encodeCall(Action.SendTx1, (target, OpenInterface.openFor.selector, payload, variables));
            bytes memory OpenForWithVariableAction =
                abi.encodeCall(Action.WithVariable, ("address sponsor", abi.encode(order.user), openForAction));

            bytes[] memory constraint = new bytes[](2 * order.inputs.length);
            // 1. User balance
            // 2. User approval
            for (uint256 i; i < constraint.length;) {
                uint256[2] memory input = order.inputs[i / 2];
                bytes memory tokenTarget = interoperableAddress(block.chainid, input[0].fromIdentifier().toIdentifier());
                // TODO: Constraints. Too many questions to implement for now.
            }
            steps[0] =
                Step({ action: OpenForWithVariableAction, constraint: constraint, dependencies: new uint256[](0) });

            return (1);
        }
        return (0);
    }

    function getFillData(
        MandateOutput memory output
    ) internal pure returns (bytes memory) { }

    function addFillSteps(
        Step[] memory steps,
        uint256 stepIndex,
        bool opened,
        StandardOrder memory order
    ) internal view returns (uint256 nextStepIndex) {
        uint256 numOutputs = order.outputs.length;
        uint256[] memory dependencies = new uint256[](opened ? 0 : 1);
        if (!opened) dependencies[0] = 0;

        uint256[] memory variables = new uint256[](3);
        variables[0] = 2;
        variables[1] = 3;
        variables[2] = 4;

        for (uint256 i; i < numOutputs; ++i) {
            MandateOutput memory output = order.outputs[i];
            bytes memory outputSettlerTarget = interoperableAddress(block.chainid, output.settler);
            bytes memory fillAction =
                abi.encodeCall(Action.SendTx2, (outputSettlerTarget, OutputSettlerBase.fill.selector, variables));
            bytes memory fillActionWithVariable =
                abi.encodeCall(Action.WithVariable, ("bytes origindata", getFillData(output), fillAction));
            steps[stepIndex++] =
                Step({ action: fillActionWithVariable, constraint: new bytes[](0), dependencies: dependencies });
        }
        // Yield
        for (uint256 i; i < numOutputs; ++i) {
            MandateOutput memory output = order.outputs[i];
            bytes memory outputSettlerTarget = interoperableAddress(block.chainid, output.settler);
            bytes memory yieldAction = abi.encodeCall(Action.Yield, (outputSettlerTarget, getFillData(output)));
            steps[stepIndex++] =
                Step({ action: yieldAction, constraint: new bytes[](0), dependencies: new uint256[](0) });
        }
        return nextStepIndex = stepIndex;
    }

    function addOracleSteps(Step[] memory steps, uint256 stepIndex) internal view returns (uint256 nextStepIndex) {
        return nextStepIndex = stepIndex;
    }

    function addFinaliseSteps(Step[] memory steps, uint256 stepIndex) internal view returns (uint256 nextStepIndex) {
        return nextStepIndex = stepIndex;
    }

    function getProceeds(
        StandardOrder memory order
    ) internal view returns (Leg[] memory proceeds) {
        // Compute the proceeds based on fixed inputs.
        proceeds = new Leg[](order.inputs.length);
        for (uint256 i; i < order.inputs.length; ++i) {
            uint256[2] memory input = order.inputs[i];
            bytes memory token = interoperableAddress(block.chainid, bytes32(input[0]));
            uint256 constAmount = input[1];
            proceeds[i] = Leg(token, abi.encodeCall(Formula.Const, constAmount));
        }
    }

    function getUntrusted(
        StandardOrder memory order
    ) internal view returns (bytes[] memory untrusted) {
        // Upper bound on untrusted is 1 + numOutputs * 2
        untrusted = new bytes[](1 + order.outputs.length * 2);
        untrusted[0] = abi.encode(block.chainid, order.inputOracle);
        for (uint256 i = 1; i < order.outputs.length * 2;) {
            unchecked {
                MandateOutput memory output = order.outputs[i / 2];
                untrusted[i++] = interoperableAddress(block.chainid, output.settler);
                untrusted[i++] = interoperableAddress(block.chainid, output.oracle);
            }
        }
        return shrink(untrusted);
    }

    function resolve(
        bytes calldata payload
    ) external view returns (ResolvedOrder memory) {
        StandardOrder memory order = abi.decode(payload, (StandardOrder));

        string[] memory variableAbiTypes;
        variableAbiTypes[0] = "address sponsor";
        variableAbiTypes[1] = "bytes sponsorSignature";
        variableAbiTypes[2] = "bytes32 orderId";
        variableAbiTypes[3] = "bytes originData";
        variableAbiTypes[4] = "bytes fillerData";

        bool opened = hasBeenOpened(order);
        // TODO: How do we contain OracleSteps?
        Step[] memory steps = new Step[](opened ? 1 + order.outputs.length * 2 : 2 + order.outputs.length * 2);

        uint256 stepIndex = getInitStep(steps, opened, payload, order);
        stepIndex = addFillSteps(steps, stepIndex, opened, order);
        // todo: How do we convey dependencies between functions here?
        stepIndex = addOracleSteps(steps, stepIndex);
        stepIndex = addFinaliseSteps(steps, stepIndex);

        return ResolvedOrder({
            steps: steps,
            variableAbiTypes: variableAbiTypes,
            costs: new Leg[](0), // Yield
            proceeds: getProceeds(order),
            untrusted: getUntrusted(order)
        });
    }
}
