// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IDestinationSettler } from "../../interfaces/IERC7683.sol";
import { IOIFCallback } from "../../interfaces/IOIFCallback.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../../libs/OutputVerificationLib.sol";

import { BaseOutputSettler } from "../BaseOutputSettler.sol";

/**
 * @dev Solvers use Oracles to pay outputs. This allows us to record the payment.
 * Tokens never touch this contract but goes directly from solver to user.
 * This filler contract only supports limit orders.
 */
contract OutputInputSettler7683 is BaseOutputSettler, IDestinationSettler {
    error NotImplemented();

    function _fill(bytes32 orderId, MandateOutput calldata output, bytes32 proposedSolver) internal override {
        uint256 amount = _getAmountMemory(output);
        _fillMemory(orderId, output, amount, proposedSolver);
    }

    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external {
        bytes32 proposedSolver;
        assembly ("memory-safe") {
            proposedSolver := calldataload(fillerData.offset)
        }

        MandateOutput memory output = abi.decode(originData, (MandateOutput));

        uint256 amount = _getAmountMemory(output);
        _fillMemory(orderId, output, amount, proposedSolver);
    }

    function _getAmountMemory(
        MandateOutput memory output
    ) internal pure returns (uint256 amount) {
        uint256 fulfillmentLength = output.context.length;
        if (fulfillmentLength == 0) return output.amount;
        bytes1 orderType = bytes1(output.context);
        if (orderType == 0x00 && fulfillmentLength == 1) return output.amount;
        revert NotImplemented();
    }

    function _fillMemory(
        bytes32 orderId,
        MandateOutput memory output,
        uint256 outputAmount,
        bytes32 proposedSolver
    ) internal {
        if (proposedSolver == bytes32(0)) revert ZeroValue();
        // Validate order context. This lets us ensure that this filler is the correct filler for the output.
        OutputVerificationLib._isThisChain(output.chainId);
        OutputVerificationLib._isThisOutputSettler(output.settler);

        // Get hash of output.
        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHashMemory(output);

        bytes32 existing = _fillRecords[orderId][outputHash];
        if (existing != bytes32(0)) revert AlreadyFilled(orderId, outputHash);

        bytes32 payloadHash = keccak256(
            MandateOutputEncodingLib.encodeFillDescriptionM(proposedSolver, orderId, uint32(block.timestamp), output)
        );

        _fillRecords[orderId][outputHash] = payloadHash;

        // Load order description.
        address recipient = address(uint160(uint256(output.recipient)));
        address token = address(uint160(uint256(output.token)));

        // Collect tokens from the user. If this fails, then the call reverts and
        // the proof is not set to true.
        SafeTransferLib.safeTransferFrom(token, msg.sender, recipient, outputAmount);

        // If there is an external call associated with the fill, execute it.
        bytes memory remoteCall = output.call;
        if (remoteCall.length > 0) IOIFCallback(recipient).outputFilled(output.token, outputAmount, remoteCall);

        emit OutputFilled(orderId, proposedSolver, uint32(block.timestamp), output);
    }
}
