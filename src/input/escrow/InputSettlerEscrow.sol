// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";

import { Output, ResolvedCrossChainOrder } from "../../interfaces/IERC7683.sol";
import { IInputSettlerEscrow } from "../../interfaces/IInputSettlerEscrow.sol";
import { IOIFCallback } from "../../interfaces/IOIFCallback.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

import { BytesLib } from "../../libs/BytesLib.sol";
import { IsContractLib } from "../../libs/IsContractLib.sol";
import { LibAddress } from "../../libs/LibAddress.sol";

import { MandateOutput } from "../types/MandateOutputType.sol";
import { OrderPurchase } from "../types/OrderPurchaseType.sol";
import { StandardOrder, StandardOrderType } from "../types/StandardOrderType.sol";

import { InputSettlerPurchase } from "../InputSettlerPurchase.sol";
import { Permit2WitnessType } from "./Permit2WitnessType.sol";

/**
 * @title OIF Input Settler supporting using an explicit escrow.
 * @notice This Catalyst Settler implementation contained an escrow to manage input assets. Intents are initiated by
 * depositing assets through either `::open` by msg.sender or `::openFor` by `order.user`. Since tokens are collected on
 * the `::open(For)` call, it is important to wait for the `::open(For)` call to be final before filling the intent.
 *
 * Using Permit2 to call `::openFor` with, `openDeadline` is identical to `order.fillDeadline`. Before calling
 * `::openFor` ensure there is sufficient time to fill.
 *
 * If an order has not been finalised / claimed before `order.expires`, anyone may call `::refund` to send
 * `order.inputs` to `order.user`. Note that if this is not done, an order finalised after `order.expires` still claims
 * `order.inputs` for the solver.
 */
contract InputSettlerEscrow is InputSettlerPurchase, IInputSettlerEscrow {
    using LibAddress for bytes32;

    error InvalidOrderStatus();
    error OrderIdMismatch(bytes32 provided, bytes32 computed);
    error InputTokenHasDirtyBits();

    event Open(bytes32 indexed orderId, StandardOrder order);
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
        name = "OIFEscrow";
        version = "1";
    }

    // --- Generic order identifier --- //

    function _orderIdentifier(
        StandardOrder calldata order
    ) internal view returns (bytes32) {
        return StandardOrderType.orderIdentifier(order);
    }

    function orderIdentifier(
        StandardOrder calldata order
    ) external view returns (bytes32) {
        return _orderIdentifier(order);
    }

    /**
     * @notice Opens an intent for `order.user`. `order.input` tokens are collected from msg.sender.
     * @param order StandardOrder representing the intent.
     */
    function open(
        StandardOrder calldata order
    ) external {
        // Validate the order structure.
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);

        bytes32 orderId = StandardOrderType.orderIdentifier(order);

        if (orderStatus[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Deposited;

        // Collect input tokens.
        uint256[2][] memory inputs = order.inputs;
        uint256 numInputs = inputs.length;
        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] memory input = inputs[i];
            address token = EfficiencyLib.asSanitizedAddress(input[0]);
            uint256 amount = input[1];
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        }

        emit Open(orderId, order);
    }

    /**
     * @notice Opens an intent for `order.user`. `order.input` tokens are collected from `order.user` through permit2.
     * @param order StandardOrder representing the intent.
     * @param signature Permit2 signature from `order.user` authorizing collection of `order.input`.
     */
    function openFor(
        StandardOrder calldata order,
        bytes calldata signature,
        bytes calldata /* originFillerData */
    ) external {
        // Validate the order structure.
        _validateInputChain(order.originChainId);
        // _validateTimestampHasNotPassed(order.openDeadline);
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);

        bytes32 orderId = _orderIdentifier(order);

        if (orderStatus[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Deposited;

        // Collect input tokens
        _openFor(order, signature, address(this));
        emit Open(orderId, order);
    }

    /**
     * @notice Helper function for using permit2 to collect assets represented by a StandardOrder.
     * @param order StandardOrder representing the intent.
     * @param signature 712 signature of permit2 structure with Permit2Witness representing `order` signed by
     * `order.user`.
     * @param to recipient of the inputs tokens. In most cases, should be address(this).
     */
    function _openFor(StandardOrder calldata order, bytes calldata signature, address to) internal {
        ISignatureTransfer.TokenPermissions[] memory permitted;
        ISignatureTransfer.SignatureTransferDetails[] memory transferDetails;

        {
            uint256[2][] calldata orderInputs = order.inputs;
            // Load the number of inputs. We need them to set the array size & convert each
            // input struct into a transferDetails struct.
            uint256 numInputs = orderInputs.length;
            permitted = new ISignatureTransfer.TokenPermissions[](numInputs);
            transferDetails = new ISignatureTransfer.SignatureTransferDetails[](numInputs);
            // Iterate through each input.
            for (uint256 i; i < numInputs; ++i) {
                uint256[2] calldata orderInput = orderInputs[i];
                uint256 inputToken = orderInput[0];
                uint256 amount = orderInput[1];
                // Validate that the input token's 12 leftmost bytes are 0.
                if ((inputToken >> 160) != 0) revert InputTokenHasDirtyBits();
                address token;
                assembly ("memory-safe") {
                    // No dirty bits exist.
                    token := inputToken
                }
                // Check if input tokens are contracts.
                IsContractLib.checkCodeSize(token);
                // Set the allowance. This is the explicit max allowed amount approved by the user.
                permitted[i] = ISignatureTransfer.TokenPermissions({ token: token, amount: amount });
                // Set our requested transfer. This has to be less than or equal to the allowance
                transferDetails[i] = ISignatureTransfer.SignatureTransferDetails({ to: to, requestedAmount: amount });
            }
        }
        ISignatureTransfer.PermitBatchTransferFrom memory permitBatch = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: order.nonce,
            deadline: order.fillDeadline
        });
        PERMIT2.permitWitnessTransferFrom(
            permitBatch,
            transferDetails,
            order.user,
            Permit2WitnessType.Permit2WitnessHash(order),
            Permit2WitnessType.PERMIT2_PERMIT2_TYPESTRING,
            signature
        );
    }

    // --- Refund --- //

    /**
     * @notice Refunds an order that has not been finalised before it expired. This order may have been filled but
     * finalise has not been called yet.
     * @param order StandardOrder description of the intent.
     */
    function refund(
        StandardOrder calldata order
    ) external {
        _validateInputChain(order.originChainId);
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
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32 solver,
        bytes32 destination
    ) internal virtual {
        _resolveLock(orderId, order.inputs, destination.fromIdentifier(), OrderStatus.Claimed);
        emit Finalised(orderId, solver, destination);
    }

    /**
     * @notice Finalises an order when called directly by the solver
     * @dev Finalise is not blocked after the expiry of orders.
     * The caller must be the address corresponding to the first solver in the solvers array.
     * @param order StandardOrder description of the intent.
     * @param timestamps Array of timestamps when each output was filled
     * @param solvers Array of solvers who filled each output (in order of outputs).
     * @param destination Address to send the inputs to. If the solver wants to send the inputs to themselves, they
     * should pass their address to this parameter.
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     */
    function finalise(
        StandardOrder calldata order,
        uint32[] calldata timestamps,
        bytes32[] calldata solvers,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        _validateDestination(destination);
        _validateInputChain(order.originChainId);

        bytes32 orderId = _orderIdentifier(order);
        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);
        _orderOwnerIsCaller(orderOwner);

        _validateFills(order.fillDeadline, order.localOracle, order.outputs, orderId, timestamps, solvers);

        _finalise(order, orderId, solvers[0], destination);

        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else using their signature
     * @dev Finalise is not blocked after the expiry of orders.
     * This function serves to finalise intents on the origin chain with proper authorization from the order owner.
     * @param order StandardOrder description of the intent.
     * @param timestamps Array of timestamps when each output was filled
     * @param solvers Array of solvers who filled each output (in order of outputs) element
     * @param destination Address to send the inputs to.
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     * @param orderOwnerSignature Signature from the order owner authorizing this external call
     */
    function finaliseWithSignature(
        StandardOrder calldata order,
        uint32[] calldata timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        _validateDestination(destination);
        _validateInputChain(order.originChainId);

        bytes32 orderId = _orderIdentifier(order);

        {
            bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);

            // Validate the external claimant with signature
            _allowExternalClaimant(
                orderId, EfficiencyLib.asSanitizedAddress(uint256(orderOwner)), destination, call, orderOwnerSignature
            );
        }

        _validateFills(order.fillDeadline, order.localOracle, order.outputs, orderId, timestamps, solvers);

        _finalise(order, orderId, solvers[0], destination);

        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    //--- Asset Lock & Escrow ---//

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

    // --- Purchase Order --- //

    /**
     * @notice This function is called to buy an order from a solver.
     * If the order was purchased in time, then when the order is settled, the inputs will go to the purchaser instead
     * of the original solver.
     * @param orderPurchase Order purchase description signed by solver.
     * @param order Order to purchase.
     * @param orderSolvedByIdentifier Solver of the order. Is not validated, if wrong the purchase will be skipped.
     * @param purchaser The new order owner.
     * @param expiryTimestamp Set to ensure if your transaction does not mine quickly, you don't end up purchasing an
     * order that you can not prove OR is outside the timeToBuy window.
     * @param solverSignature EIP712 Signature of OrderPurchase by orderOwner.
     */
    function purchaseOrder(
        OrderPurchase calldata orderPurchase,
        StandardOrder calldata order,
        bytes32 orderSolvedByIdentifier,
        bytes32 purchaser,
        uint256 expiryTimestamp,
        bytes calldata solverSignature
    ) external virtual {
        bytes32 computedOrderId = _orderIdentifier(order);
        // Sanity check to ensure the user thinks they are buying the right order.
        if (computedOrderId != orderPurchase.orderId) revert OrderIdMismatch(orderPurchase.orderId, computedOrderId);

        _purchaseOrder(
            orderPurchase, order.inputs, orderSolvedByIdentifier, purchaser, expiryTimestamp, solverSignature
        );
    }
}
