// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";

import {
    FillInstruction,
    GaslessCrossChainOrder,
    IOriginSettler,
    OnchainCrossChainOrder,
    Open,
    Output,
    ResolvedCrossChainOrder
} from "../../interfaces/IERC7683.sol";

import { IInputSettler7683 } from "../../interfaces/IInputSettler7683.sol";
import { IOIFCallback } from "../../interfaces/IOIFCallback.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { BytesLib } from "../../libs/BytesLib.sol";
import { IsContractLib } from "../../libs/IsContractLib.sol";
import { MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";
import { MandateOutput } from "../types/MandateOutputType.sol";

import { BaseInputSettler } from "../BaseInputSettler.sol";

import { MultichainOrderComponent, MultichainOrderComponentType } from "../types/MultichainOrderComponentType.sol";

/**
 * @title OIF Input Settler using supporting multichain escrows.
 * @notice This OIF Input Settler implementation uses an explicit escrow as a deposit scheme.
 *
 * This contract does not support fee on transfer tokens.
 */
contract InputSettlerMultichainEscrow is BaseInputSettler {
    error NotOrderOwner();
    error DeadlinePassed();
    error NoDestination();
    error InvalidOrderStatus();
    error InvalidTimestampLength();
    error FilledTooLate(uint32 expected, uint32 actual);
    error WrongChain(uint256 expected, uint256 actual);

    enum OrderStatus {
        None,
        Deposited,
        Claimed,
        Refunded
    }

    mapping(bytes32 orderId => OrderStatus) _deposited;

    // Address of the Permit2 contract.
    ISignatureTransfer constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function _domainNameAndVersion()
        internal
        pure
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "MultichainEscrowOIF";
        version = "1";
    }

    // Generic order identifier
    function orderIdentifier(
        MultichainOrderComponent calldata order
    ) public view returns (bytes32) {
        return MultichainOrderComponentType.orderIdentifier(order);
    }

    /**
     * @notice Checks that this is the right chain for the order.
     * @param chainId Expected chainId for order. Will be checked against block.chainid
     */
    function _isThisChain(
        uint256 chainId
    ) internal view {
        if (chainId != block.chainid) revert WrongChain(chainId, block.chainid);
    }

    /**
     * @notice Checks that a timestamp has not expired.
     * @param timestamp The timestamp to validate that it is not less than block.timestamp
     */
    function _validateDeadline(
        uint256 timestamp
    ) internal view {
        if (block.timestamp > timestamp) revert DeadlinePassed();
    }

    function open(
        // TODO: bytes.
        MultichainOrderComponent calldata order
    ) external {
        // Validate the ERC7683 structure.
        _validateDeadline(order.fillDeadline);
        _validateDeadline(order.expires);

        bytes32 orderId = orderIdentifier(order);

        if (_deposited[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a local-reentry check.
        _deposited[orderId] = OrderStatus.Deposited;

        // Collect input tokens.
        uint256[2][] calldata inputs = order.inputs;
        uint256 numInputs = inputs.length;
        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];

            address token = EfficiencyLib.asSanitizedAddress(input[0]);
            uint256 amount = input[1];
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        }

        //emit Open(orderId, _resolve(uint32(0), orderId, compactOrder));
    }

    // --- Output Proofs --- //

    function _proofPayloadHash(
        bytes32 orderId,
        bytes32 solver,
        uint32 timestamp,
        MandateOutput calldata output
    ) internal pure returns (bytes32 outputHash) {
        return keccak256(MandateOutputEncodingLib.encodeFillDescription(solver, orderId, timestamp, output));
    }

    /**
     * @notice Check if a series of outputs have been proven.
     * @dev This function returns true if the order contains no outputs.
     * That means any order that has no outputs specified can be claimed.
     */
    function _validateFills(
        MultichainOrderComponent calldata order,
        bytes32 orderId,
        bytes32[] memory solvers,
        uint32[] calldata timestamps
    ) internal view {
        MandateOutput[] calldata MandateOutputs = order.outputs;

        uint256 numOutputs = MandateOutputs.length;
        uint256 numTimestamps = timestamps.length;
        if (numTimestamps != numOutputs) revert InvalidTimestampLength();

        uint32 fillDeadline = order.fillDeadline;
        bytes memory proofSeries = new bytes(32 * 4 * numOutputs);
        for (uint256 i; i < numOutputs; ++i) {
            uint32 outputFilledAt = timestamps[i];
            if (fillDeadline < outputFilledAt) revert FilledTooLate(fillDeadline, outputFilledAt);

            MandateOutput calldata output = MandateOutputs[i];
            bytes32 payloadHash = _proofPayloadHash(orderId, solvers[i], outputFilledAt, output);

            uint256 chainId = output.chainId;
            bytes32 outputOracle = output.oracle;
            bytes32 outputSettler = output.settler;
            assembly ("memory-safe") {
                let offset := add(add(proofSeries, 0x20), mul(i, 0x80))
                mstore(offset, chainId)
                mstore(add(offset, 0x20), outputOracle)
                mstore(add(offset, 0x40), outputSettler)
                mstore(add(offset, 0x60), payloadHash)
            }
        }
        IOracle(order.localOracle).efficientRequireProven(proofSeries);
    }

    // --- Finalise Orders --- //

    /**
     * @notice Enforces that the caller is the order owner.
     * @dev Only reads the rightmost 20 bytes to allow solvers to opt-in to Compact transfers instead of withdrawals.
     * @param orderOwner The order owner. The leftmost 12 bytes are not read.
     */
    function _orderOwnerIsCaller(
        bytes32 orderOwner
    ) internal view {
        if (EfficiencyLib.asSanitizedAddress(uint256(orderOwner)) != msg.sender) revert NotOrderOwner();
    }

    /**
     * @notice Finalise an order, paying the inputs to the solver.
     * @param order that has been filled.
     * @param orderId A unique identifier for the order.
     * @param solver Solver of the outputs.
     * @param destination Destination of the inputs funds signed for by the user.
     */
    function _finalise(
        MultichainOrderComponent calldata order,
        bytes32 orderId,
        bytes32 solver,
        bytes32 destination
    ) internal virtual {
        _resolveLock(orderId, order.inputs, EfficiencyLib.asSanitizedAddress(uint256(destination)));
        emit Finalised(orderId, solver, destination);
    }

    /**
     * @notice Finalises an order when called directly by the solver
     * @dev The caller must be the address corresponding to the first solver in the solvers array.
     * @param order StandardOrder signed in conjunction with a Compact to form an order
     * @param timestamps Array of timestamps when each output was filled
     * @param solvers Array of solvers who filled each output (in order of outputs).
     * @param destination Where to send the inputs. If the solver wants to send the inputs to themselves, they should
     * pass their address to this parameter.
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     */
    function finalise(
        MultichainOrderComponent calldata order,
        uint32[] calldata timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        if (destination == bytes32(0)) revert NoDestination();

        bytes32 orderId = orderIdentifier(order);
        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);
        _orderOwnerIsCaller(orderOwner);

        _validateFills(order, orderId, solvers, timestamps);

        _finalise(order, orderId, solvers[0], destination);

        // TODO:
        // if (call.length > 0) {
        //     IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        // }
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else using their signature
     * @dev This function serves to finalise intents on the origin chain with proper authorization from the order owner.
     * @param order StandardOrder signed in conjunction with a Compact to form an order
     * @param timestamps Array of timestamps when each output was filled
     * @param solvers Array of solvers who filled each output (in order of outputs)
     * element
     * @param destination Where to send the inputs
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     * @param orderOwnerSignature Signature from the order owner authorizing this external call
     */
    function finaliseWithSignature(
        MultichainOrderComponent calldata order,
        uint32[] calldata timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        if (destination == bytes32(0)) revert NoDestination();

        bytes32 orderId = orderIdentifier(order);
        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);

        // Validate the external claimant with signature
        _allowExternalClaimant(
            orderId, EfficiencyLib.asSanitizedAddress(uint256(orderOwner)), destination, call, orderOwnerSignature
        );

        _validateFills(order, orderId, solvers, timestamps);

        _finalise(order, orderId, solvers[0], destination);

        // if (call.length > 0) {
        //     IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        // }
    }

    //--- The Compact & Resource Locks ---//

    /**
     * @dev This function employs a local reentry guard: we check the order status and then we update it afterwards. This
     * is an important check as it is indeed to process external ERC20 transfers.
     */
    function _resolveLock(bytes32 orderId, uint256[2][] calldata inputs, address destination) internal virtual {
        // Check the order status:
        if (_deposited[orderId] != OrderStatus.Deposited) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        _deposited[orderId] = OrderStatus.Claimed;

        // We have now ensured that this point can only be reached once. We can now process the asset delivery.
        uint256 numInputs = inputs.length;
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];
            // Check if the input is for this chain.

            address token = EfficiencyLib.asSanitizedAddress(input[0]);
            uint256 amount = input[1];
            SafeTransferLib.safeTransfer(token, destination, amount);
        }
    }
}
