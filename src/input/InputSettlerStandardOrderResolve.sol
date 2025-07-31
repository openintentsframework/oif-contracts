// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "../libs/LibAddress.sol";
import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";

import { MandateOutput } from "./types/MandateOutputType.sol";
import { StandardOrderType } from "./types/StandardOrderType.sol";

import { MandateOutputEncodingLib } from "../libs/MandateOutputEncodingLib.sol";
import { MandateOutput } from "./types/MandateOutputType.sol";

struct Output {
    bytes32 token;
    uint256 amount;
    bytes32 recipient;
    uint256 chainId;
}

struct FillInstruction {
    uint64 destinationChainId;
    bytes32 destinationSettler;
    bytes originData;
}

struct Extension {
    string abiDescription;
    bytes data;
}

struct ResolvedCrossChainOrder {
    address user;
    uint256 originChainId;
    uint32 openDeadline;
    uint32 fillDeadline;
    uint32 settlementDeadline;
    bytes32 orderId;
    Output[] minReceived;
    FillInstruction[] fillInstructions;
    Extension[] extensions;
}

/**
 * @title Resolves Standard Orders through 7683 interfaces
 */
abstract contract InputSettlerStandardOrderResolve {
    using StandardOrderType for bytes;

    function resolve(
        address sponsor,
        bytes calldata order,
        bytes calldata signature
    ) external view virtual returns (ResolvedCrossChainOrder memory) {
        return _resolve(sponsor, order, signature);
    }

    function _validateSignature(
        address sponsor,
        bytes calldata order,
        bytes calldata signature
    ) internal view virtual;

    function _resolveExtensions(
        address,
        bytes calldata order,
        bytes calldata
    ) internal view virtual returns (Extension[] memory extensions) {
        extensions = new Extension[](2);
        extensions[0] = Extension({ abiDescription: "OIF()", data: hex"" });
        extensions[1] = Extension({ abiDescription: "inputOracle(address)", data: abi.encode(order.localOracle()) });
    }

    function _resolve(
        address sponsor,
        bytes calldata order,
        bytes calldata signature
    ) internal view returns (ResolvedCrossChainOrder memory) {
        _validateSignature(sponsor, order, signature);

        uint256 inputChainId = order.originChainId();

        uint256[2][] calldata orderInputs = order.inputs();
        uint256 numInputs = orderInputs.length;
        // Set input description.
        Output[] memory inputs = new Output[](numInputs);
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] calldata orderInput = orderInputs[i];
            uint256 token = orderInput[0];
            uint256 amount = orderInput[1];

            inputs[i] = Output({ token: bytes32(token), amount: amount, recipient: bytes32(0), chainId: inputChainId });
        }

        MandateOutput[] calldata orderOutputs = order.outputs();
        uint256 numOutputs = orderOutputs.length;
        // Set Output description.
        Output[] memory outputs = new Output[](numOutputs);
        // Set instructions
        FillInstruction[] memory instructions = new FillInstruction[](numOutputs);
        for (uint256 i; i < numOutputs; ++i) {
            MandateOutput memory orderOutput = orderOutputs[i];

            outputs[i] = Output({
                token: orderOutput.token,
                amount: orderOutput.amount,
                recipient: orderOutput.recipient,
                chainId: orderOutput.chainId
            });

            instructions[i] = FillInstruction({
                destinationChainId: uint64(orderOutput.chainId),
                destinationSettler: orderOutput.settler,
                originData: abi.encode(orderOutput)
            });
        }

        return ResolvedCrossChainOrder({
            user: order.user(),
            originChainId: inputChainId,
            openDeadline: order.fillDeadline(),
            fillDeadline: order.fillDeadline(),
            settlementDeadline: order.expires(),
            orderId: order.orderIdentifier(),
            minReceived: inputs,
            fillInstructions: instructions,
            extensions: _resolveExtensions(sponsor, order, signature)
        });
    }
}
