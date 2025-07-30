// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IDestinationSettler } from "../../interfaces/IERC7683.sol";
import { IOutputCallback } from "../../interfaces/IOutputCallback.sol";

import { LibAddress } from "../../libs/LibAddress.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../../libs/OutputVerificationLib.sol";

import { BaseOutputSettler } from "../BaseOutputSettler.sol";

/**
 * @dev Solvers use Oracles to pay outputs. This allows us to record the payment.
 * Tokens never touch this contract but goes directly from solver to user.
 * This output settler contract only supports limit orders.
 */
contract OutputInputSettlerEscrow is BaseOutputSettler, IDestinationSettler {
    using LibAddress for address;

    error NotImplemented();

    /**
     * @dev Virtual function for extensions to implement output resolution logic.
     * @param output The given output to resolve.
     * @param proposedSolver The proposed solver to check exclusivity against.
     * @return amount The computed amount for the output.
     */
    function _resolveOutput(
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) internal pure override returns (uint256 amount) {
        uint256 fulfillmentLength = output.context.length;
        if (fulfillmentLength == 0) return output.amount;
        bytes1 orderType = bytes1(output.context);
        if (orderType == 0x00 && fulfillmentLength == 1) return output.amount;
        revert NotImplemented();
    }

    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external {
        bytes32 proposedSolver;
        assembly ("memory-safe") {
            proposedSolver := calldataload(fillerData.offset)
        }

        MandateOutput memory output = abi.decode(originData, (MandateOutput));

        // For memory outputs, we need to use the internal _fillMemory function
        uint256 outputAmount = _resolveOutputMemory(output, proposedSolver);

        bytes32 existingFillRecordHash = _fillMemory(orderId, output, outputAmount, proposedSolver);
        if (existingFillRecordHash != bytes32(0)) revert AlreadyFilled();
    }

    /**
     * @dev Memory version of _resolveOutput for internal use with memory outputs
     */
    function _resolveOutputMemory(
        MandateOutput memory output,
        bytes32 proposedSolver
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
    ) internal virtual returns (bytes32 existingFillRecordHash) {
        if (proposedSolver == bytes32(0)) revert ZeroValue();
        OutputVerificationLib._isThisChain(output.chainId);
        OutputVerificationLib._isThisOutputSettler(output.settler);

        bytes32 outputHash = MandateOutputEncodingLib.getMandateOutputHashMemory(output);
        existingFillRecordHash = _fillRecords[orderId][outputHash];
        if (existingFillRecordHash != bytes32(0)) return existingFillRecordHash; // Early return if already solved.
        // The above and below lines act as a local re-entry check.
        uint32 fillTimestamp = uint32(block.timestamp);
        _fillRecords[orderId][outputHash] = _getFillRecordHash(proposedSolver, fillTimestamp);

        // Storage has been set. Fill the output.
        address recipient = address(uint160(uint256(output.recipient)));
        SafeTransferLib.safeTransferFrom(address(uint160(uint256(output.token))), msg.sender, recipient, outputAmount);
        if (output.call.length > 0) IOutputCallback(recipient).outputFilled(output.token, outputAmount, output.call);

        emit OutputFilled(orderId, proposedSolver, fillTimestamp, output, outputAmount);
    }
}
