// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import { LibAddress } from "../libs/LibAddress.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";

import { IInputCallback } from "../interfaces/IInputCallback.sol";
import { IOutputCallback } from "../interfaces/IOutputCallback.sol";

/**
 * @title Allows a user to specify a series of calls that should be made by the handler
 * via the message field in the deposit.
 * @notice Fork of Across Multicall Contract.
 * @dev This contract makes the calls blindly.
 * The caller should ensure that the tokens received by the handler are completely consumed
 * otherwise they will be left in the contract free to take for next the next caller.
 */
contract CatsMulticallHandler is IInputCallback, IOutputCallback, ReentrancyGuard {
    using LibAddress for address;
    using LibAddress for bytes32;

    struct Call {
        address target;
        bytes callData;
        uint256 value;
    }

    struct Instructions {
        // If set to an address (not address(0)), then the tokens sent to this contract on the call
        // will be approved for this address.
        address setApprovalsUsingInputsFor;
        //  Calls that will be attempted.
        Call[] calls;
        // Where the tokens go if any part of the call fails.
        // Leftover tokens are sent here as well if the action succeeds.
        address fallbackRecipient;
    }

    // Emitted when one of the calls fails. Note: all calls are reverted in this case.
    event CallsFailed(Call[] calls, address indexed fallbackRecipient);

    // Emitted when there are leftover tokens that are sent to the fallbackRecipient.
    event DrainedTokens(address indexed recipient, address indexed token, uint256 indexed amount);

    // Errors
    error CallReverted(uint256 index, Call[] calls); // 0xe462c440
    error NotSelf(); // 0x29c3b7ee
    error InvalidCall(uint256 index, Call[] calls); // 0xe237730c

    modifier onlySelf() {
        _requireSelf();
        _;
    }

    // --- Entrypoints --- //

    /**
     * @notice Entrypoint for the handler called by the SpokePool contract.
     * @dev This will execute all calls encoded in the msg. The caller is responsible for making sure all tokens are
     * drained from this contract by the end of the series of calls. If not, they can be stolen.
     * A drainLeftoverTokens call can be included as a way to drain any remaining tokens from this contract.
     * @param message abi encoded array of Call structs, containing a target, callData, and value for each call that
     * the contract should make.
     */
    function handleV3AcrossMessage(
        address token,
        uint256 amount,
        address,
        bytes memory message
    ) external nonReentrant {
        Instructions memory instructions = abi.decode(message, (Instructions));

        // Set approvals base on inputs if requested.
        if (instructions.setApprovalsUsingInputsFor != address(0)) {
            _setApproval(token, amount, instructions.setApprovalsUsingInputsFor);
        }

        // Execute attached instructions
        _doInstructions(instructions);

        if (instructions.fallbackRecipient == address(0)) return;
        // If there are leftover tokens, send them to the fallback recipient regardless of execution success.
        _drainRemainingTokens(token, payable(instructions.fallbackRecipient));
    }

    /**
     * @notice Entrypoint for the catalyst handler if an output has been delivered.
     * @dev Please make sure to empty the contract of tokens after your call otherwise they can be taken by someone
     * else.
     */
    function outputFilled(bytes32 token, uint256 amount, bytes calldata executionData) external nonReentrant {
        Instructions memory instructions = abi.decode(executionData, (Instructions));

        // Set approvals base on inputs if requested.
        if (instructions.setApprovalsUsingInputsFor != address(0)) {
            _setApproval(token.fromIdentifier(), amount, instructions.setApprovalsUsingInputsFor);
        }

        // Execute attached instructions
        _doInstructions(instructions);

        if (instructions.fallbackRecipient == address(0)) return;
        // If there are leftover tokens, send them to the fallback recipient regardless of execution success.
        _drainRemainingTokens(token.fromIdentifier(), payable(instructions.fallbackRecipient));
    }

    /**
     * @notice Entrypoint for the catalyst handler if inputs are delivered.
     * @dev Please make sure to empty the contract of tokens after your call otherwise they can be taken by someone
     * else.
     */
    function orderFinalised(uint256[2][] calldata inputs, bytes calldata executionData) external nonReentrant {
        Instructions memory instructions = abi.decode(executionData, (Instructions));
        // Set approvals base on inputs if requested.
        if (instructions.setApprovalsUsingInputsFor != address(0)) {
            _setApprovals(inputs, instructions.setApprovalsUsingInputsFor);
        }

        // Execute attached instructions
        _doInstructions(instructions);

        if (instructions.fallbackRecipient == address(0)) return;
        // If there are leftover tokens, send them to the fallback recipient regardless of execution success.
        uint256 numInputs = inputs.length;
        for (uint256 i; i < numInputs; ++i) {
            _drainRemainingTokens(
                EfficiencyLib.asSanitizedAddress(inputs[i][0]), payable(instructions.fallbackRecipient)
            );
        }
    }

    // --- Code dedublication --- //

    /**
     * @notice Helper function to execute attached instructions.
     */
    function _doInstructions(
        Instructions memory instructions
    ) internal {
        // If there is no fallback recipient, call and revert if the inner call fails.
        if (instructions.fallbackRecipient == address(0)) {
            this.attemptCalls(instructions.calls);
            return;
        }

        // Otherwise, try the call and send to the fallback recipient if any tokens are leftover.
        (bool success,) = address(this).call(abi.encodeCall(this.attemptCalls, (instructions.calls)));
        if (!success) emit CallsFailed(instructions.calls, instructions.fallbackRecipient);
    }

    /**
     * @notice Sets approval for a token.
     */
    function _setApproval(address token, uint256 amount, address to) internal {
        SafeTransferLib.safeApproveWithRetry(token, to, amount);
    }

    /**
     * @notice Set approvals for a list of tokens.
     */
    function _setApprovals(uint256[2][] calldata inputs, address to) internal {
        uint256 numInputs = inputs.length;
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];
            uint256 token = input[0];
            uint256 amount = input[1];
            SafeTransferLib.safeApproveWithRetry(EfficiencyLib.asSanitizedAddress(token), to, amount);
        }
    }

    /**
     * @notice Drain remaining tokens
     * @param token Token to drain
     * @param destination Target for the tokens
     */
    function _drainRemainingTokens(address token, address payable destination) internal {
        if (token != address(0)) {
            // ERC20 token.
            uint256 amount = SafeTransferLib.balanceOf(token, address(this));
            if (amount > 0) {
                SafeTransferLib.safeTransfer(token, destination, amount);
                emit DrainedTokens(destination, token, amount);
            }
        } else {
            // Send native token
            uint256 amount = address(this).balance;
            if (amount > 0) SafeTransferLib.safeTransferETH(destination, amount);
        }
    }

    /**
     * @notice External helper to drain remaining tokens. Can be called as an instruction to empty other tokens.
     */
    function drainLeftoverTokens(address token, address payable destination) external onlySelf {
        _drainRemainingTokens(token, destination);
    }

    // --- Helpers ---//

    function attemptCalls(
        Call[] memory calls
    ) external onlySelf {
        uint256 length = calls.length;
        for (uint256 i = 0; i < length; ++i) {
            Call memory call = calls[i];

            // If we are calling an EOA with calldata, assume target was incorrectly specified and revert.
            if (call.callData.length > 0 && call.target.code.length == 0) revert InvalidCall(i, calls);

            // wake-disable-next-line reentrancy
            (bool success,) = call.target.call{ value: call.value }(call.callData);
            if (!success) revert CallReverted(i, calls);
        }
    }

    function _requireSelf() internal view {
        // Must be called by this contract to ensure that this cannot be triggered without the explicit consent of the
        // depositor (for a valid relay).
        if (msg.sender != address(this)) revert NotSelf();
    }

    // Used if the caller is trying to unwrap the native token to this contract.
    receive() external payable { }
}
