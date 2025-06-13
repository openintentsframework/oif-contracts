// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IDestinationSettler } from "../../interfaces/IERC7683.sol";
import { IOIFCallback } from "../../interfaces/IOIFCallback.sol";

import { LibAddress } from "../../libs/LibAddress.sol";
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

    using LibAddress for address;

    function _fill(
        bytes32 orderId,
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) internal override returns (bytes32 recordedSolver) {
        uint256 amount = _getAmountMemory(output);
        recordedSolver = _fillMemory(orderId, output, amount, proposedSolver);
        if (recordedSolver != proposedSolver) revert FilledBySomeoneElse(recordedSolver);
    }

    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external {
        bytes32 proposedSolver;
        assembly ("memory-safe") {
            proposedSolver := calldataload(fillerData.offset)
        }

        MandateOutput memory output = abi.decode(originData, (MandateOutput));

        uint256 amount = _getAmountMemory(output);
        bytes32 recordedSolver = _fillMemory(orderId, output, amount, proposedSolver);
        if (recordedSolver != proposedSolver) revert FilledBySomeoneElse(recordedSolver);
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
    ) internal returns (bytes32) {
        if (proposedSolver == bytes32(0)) revert ZeroValue();
        // Validate order context. This lets us ensure that this filler is the correct filler for the output.
        OutputVerificationLib._isThisChain(output.chainId);
        OutputVerificationLib._isThisOutputSettler(output.settler);

        // Get hash of output.
        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHashMemory(output);

        // Get the proof state of the fulfillment.
        bytes32 existingSolver = filledOutputs[orderId][outputHash];

        // Early return if we have already seen proof.
        if (existingSolver != bytes32(0)) return existingSolver;

        // The fill status is set before the transfer.
        // This allows the above code-chunk to act as a local re-entry check.
        filledOutputs[orderId][outputHash] = proposedSolver;

        // Set the associated attestation as true. This allows the filler to act as an oracle and check whether payload
        // hashes have been filled. Note that within the payload we set the current timestamp. This
        // timestamp needs to be collected from the event (or tx) to be able to reproduce the payload(hash)
        bytes32 dataHash = keccak256(
            MandateOutputEncodingLib.encodeFillDescriptionM(proposedSolver, orderId, uint32(block.timestamp), output)
        );
        _attestations[block.chainid][address(this).toIdentifier()][address(this).toIdentifier()][dataHash] = true;

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

        return proposedSolver;
    }
}
