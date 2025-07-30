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
import { IInputSettlerEscrow } from "../../interfaces/IInputSettlerEscrow.sol";
import { IOIFCallback } from "../../interfaces/IOIFCallback.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { BytesLib } from "../../libs/BytesLib.sol";
import { IsContractLib } from "../../libs/IsContractLib.sol";
import { MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";
import { MandateOutput } from "../types/MandateOutputType.sol";
import { LibAddress } from "../../libs/LibAddress.sol";
import { MultichainOrderComponent, MultichainOrderComponentType } from "../types/MultichainOrderComponentType.sol";

import { InputSettlerBase } from "../InputSettlerBase.sol";


/**
 * @title OIF Input Settler using supporting multichain escrows.
 * @notice This OIF Input Settler implementation uses an explicit escrow as a deposit scheme.
 *
 * This contract does not support fee on transfer tokens.
 */
contract InputSettlerMultichainEscrow is InputSettlerBase {
    using LibAddress for bytes32;

    error InvalidOrderStatus();

    event Refunded(bytes32 indexed orderId);

    enum OrderStatus {
        None,
        Deposited,
        Claimed,
        Refunded
    }

    mapping(bytes32 orderId => OrderStatus) public orderStatus;

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

    // --- Generic order identifier --- //
    function _orderIdentifier(
        MultichainOrderComponent calldata order
    ) internal view returns (bytes32) {
        return MultichainOrderComponentType.orderIdentifier(order);
    }

    function orderIdentifier(
        MultichainOrderComponent calldata order
    ) external view returns (bytes32) {
        return _orderIdentifier(order);
    }

    function open(
        MultichainOrderComponent calldata order
    ) external {
        // Validate the order structure.
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);
        _validateInputChain(order.chainIdField);

        bytes32 orderId = _orderIdentifier(order);

        if (orderStatus[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a local-reentry check.
        orderStatus[orderId] = OrderStatus.Deposited;

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

    // --- Refund --- //

    /**
     * @notice Refunds an order that has not been finalised before it expired. This order may have been filled but
     * finalise has not been called yet.
     * @param order StandardOrder description of the intent.
     */
    function refund(
        MultichainOrderComponent calldata order
    ) external {
        _validateInputChain(order.chainIdField);
        _validateTimestampHasPassed(order.expires);

        bytes32 orderId = _orderIdentifier(order);
        _resolveLock(orderId, order.inputs, order.user, OrderStatus.Refunded);
        emit Refunded(orderId);
    }


    // --- Finalise Orders --- //

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
        _resolveLock(orderId, order.inputs, destination.fromIdentifier(), OrderStatus.Claimed);
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
        _validateDestination(destination);
        _validateInputChain(order.chainIdField);

        bytes32 orderId = _orderIdentifier(order);
        _validateIsCaller(solvers[0]);

        _validateFills(order.fillDeadline, order.localOracle, order.outputs, orderId, timestamps, solvers);

        _finalise(order, orderId, solvers[0], destination);

        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
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
        _validateDestination(destination);
        _validateInputChain(order.chainIdField);

        bytes32 orderId = _orderIdentifier(order);

        // Validate the external claimant with signature
        _allowExternalClaimant(
            orderId, solvers[0].fromIdentifier(), destination, call, orderOwnerSignature
        );

        _validateFills(order.fillDeadline, order.localOracle, order.outputs, orderId, timestamps, solvers);

        _finalise(order, orderId, solvers[0], destination);

        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    //--- The Compact & Resource Locks ---//

    /**
     * @dev This function employs a local reentry guard: we check the order status and then we update it afterwards.
     * This is an important check as it is indeed to process external ERC20 transfers.
     * @param newStatus specifies the new status to set the order to. Should never be OrderStatus.Deposited.
     */
    function _resolveLock(
        bytes32 orderId,
        uint256[2][] calldata inputs,
        address destination,
        OrderStatus newStatus
    ) internal virtual {
        // Check the order status:
        if (orderStatus[orderId] != OrderStatus.Deposited) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = newStatus;

        // We have now ensured that this point can only be reached once. We can now process the asset delivery.
        uint256 numInputs = inputs.length;
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];
            address token = EfficiencyLib.asSanitizedAddress(input[0]);
            uint256 amount = input[1];

            SafeTransferLib.safeTransfer(token, destination, amount);
        }
    }
}
