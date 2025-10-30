// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { EIP712 } from "openzeppelin/utils/cryptography/EIP712.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { IInputCallback } from "../../interfaces/IInputCallback.sol";
import { IInputOracle } from "../../interfaces/IInputOracle.sol";
import { IInputSettlerEscrow } from "../../interfaces/IInputSettlerEscrow.sol";
import { BytesLib } from "../../libs/BytesLib.sol";
import { IsContractLib } from "../../libs/IsContractLib.sol";

import { LibAddress } from "../../libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";
import { MandateOutput } from "../types/MandateOutputType.sol";
import { MultichainOrderComponent, MultichainOrderComponentType } from "../types/MultichainOrderComponentType.sol";

import { InputSettlerBase } from "../InputSettlerBase.sol";
import { Permit2MultichainWitnessType } from "./Permit2MultichainWitnessType.sol";

/**
 * @title OIF Input Settler using an explicit multichain escrows.
 * @notice This Input Settler implementation uses an explicit escrow as a deposit scheme.
 * This contract manages collecting input assets (through `open` and `openFor`) and releasing assets to solvers.
 * It can collect tokens using Permit2.
 *
 * A multichain intent is an intent that collects tokens on multiple chains in exchange for single set of outputs. Using
 * Permit2, a user has to sign once for each chain they wanna add to their intent. Partially signed / funded intents
 * should be treated as only having committed funds.
 *
 * If a multichain intent contains 3 chains but is only opened on 2, then the intent is still valid for those 2 chains.
 * The reduction in solver payment is equal to the missing component.
 *
 * This contract does not support fee on transfer tokens.
 */
contract InputSettlerMultichainEscrow is InputSettlerBase {
    using LibAddress for bytes32;
    using LibAddress for uint256;

    /**
     * @dev The order status is invalid.
     */
    error InvalidOrderStatus();
    /**
     * @dev Mismatch between the provided and computed order IDs.
     */
    error OrderIdMismatch(bytes32 provided, bytes32 computed);
    /**
     * @dev Mismatch between the number of inputs and signatures.
     */
    error SignatureAndInputsNotEqual();
    /**
     * @dev Reentrancy detected.
     */
    error ReentrancyDetected();
    /**
     * Signature type not supported.
     */
    error SignatureNotSupported(bytes1);

    event Open(bytes32 indexed orderId, bytes order);
    event Refunded(bytes32 indexed orderId);

    bytes1 internal constant SIGNATURE_TYPE_PERMIT2 = 0x00;
    bytes1 internal constant SIGNATURE_TYPE_SELF = 0xff;

    enum OrderStatus {
        None,
        Deposited,
        Claimed,
        Refunded
    }

    mapping(bytes32 orderId => OrderStatus) public orderStatus;

    // Address of the Permit2 contract.
    ISignatureTransfer constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    constructor() EIP712("OIFMultichainEscrow", "1") { }

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

        _open(order);

        emit Open(orderId, abi.encode(order));
    }

    function _open(
        MultichainOrderComponent calldata order
    ) internal {
        // Collect input tokens.
        uint256[2][] calldata inputs = order.inputs;
        uint256 numInputs = inputs.length;
        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];

            address token = input[0].fromIdentifier();
            uint256 amount = input[1];
            SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        }
    }

    function openFor(
        MultichainOrderComponent calldata order,
        address sponsor,
        bytes calldata signature
    ) external {
        // Validate the order structure.
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);

        bytes32 orderId = _orderIdentifier(order);

        if (orderStatus[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Deposited;

        // Check the first byte of the signature for signature type then collect inputs.
        bytes1 signatureType = signature.length > 0 ? signature[0] : SIGNATURE_TYPE_SELF;
        if (signatureType == SIGNATURE_TYPE_PERMIT2) {
            _openForWithPermit2(order, orderId, sponsor, signature[1:], address(this));
        } else if (msg.sender == sponsor && signatureType == SIGNATURE_TYPE_SELF) {
            _open(order);
        } else {
            revert SignatureNotSupported(signatureType);
        }

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Deposited) revert ReentrancyDetected();

        emit Open(orderId, abi.encode(order));
    }

    /**
     * @notice Helper function for using permit2 to collect assets represented by a StandardOrder.
     * @param order StandardOrder representing the intent.
     * @param signer Provider of the permit2 funds and signer of the intent.
     * @param signature permit2 signature with Permit2Witness representing `order` signed by `order.user`.
     * @param to recipient of the inputs tokens. In most cases, should be address(this).
     */
    function _openForWithPermit2(
        MultichainOrderComponent calldata order,
        bytes32 orderId,
        address signer,
        bytes calldata signature,
        address to
    ) internal {
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
                // Validate that the input token's 12 leftmost bytes are 0. See non-multichain escrow.
                address token = inputToken.validatedCleanAddress();
                // Check if input tokens are contracts.
                IsContractLib.validateContainsCode(token);
                // Set the allowance. This is the explicit max allowed amount approved by the user.
                permitted[i] = ISignatureTransfer.TokenPermissions({ token: token, amount: amount });
                // Set our requested transfer. This has to be less than or equal to the allowance
                transferDetails[i] = ISignatureTransfer.SignatureTransferDetails({ to: to, requestedAmount: amount });
            }
        }
        ISignatureTransfer.PermitBatchTransferFrom memory permitBatch = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted, nonce: order.nonce, deadline: order.fillDeadline
        });
        PERMIT2.permitWitnessTransferFrom(
            permitBatch,
            transferDetails,
            signer,
            Permit2MultichainWitnessType.MultichainPermit2WitnessHash(orderId, order),
            Permit2MultichainWitnessType.PERMIT2_MULTICHAIN_PERMIT2_TYPESTRING,
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
     * @param solveParams List of solve parameters for when the outputs were filled
     * @param destination Where to send the inputs. If the solver wants to send the inputs to themselves, they should
     * pass their address to this parameter.
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     */
    function finalise(
        MultichainOrderComponent calldata order,
        SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        _validateDestination(destination);
        _validateInputChain(order.chainIdField);

        bytes32 orderId = _orderIdentifier(order);
        _validateIsCaller(solveParams[0].solver);

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);

        _finalise(order, orderId, solveParams[0].solver, destination);

        if (call.length > 0) IInputCallback(destination.fromIdentifier()).orderFinalised(order.inputs, call);
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else using their signature
     * @dev This function serves to finalise intents on the origin chain with proper authorization from the order owner.
     * @param order StandardOrder signed in conjunction with a Compact to form an order
     * @param solveParams List of solve parameters for when the outputs were filled
     * @param destination Where to send the inputs
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     * @param orderOwnerSignature Signature from the order owner authorizing this external call
     */
    function finaliseWithSignature(
        MultichainOrderComponent calldata order,
        SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        _validateDestination(destination);
        _validateInputChain(order.chainIdField);

        bytes32 orderId = _orderIdentifier(order);

        // Validate the external claimant with signature
        _allowExternalClaimant(orderId, solveParams[0].solver.fromIdentifier(), destination, call, orderOwnerSignature);

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);

        _finalise(order, orderId, solveParams[0].solver, destination);

        if (call.length > 0) IInputCallback(destination.fromIdentifier()).orderFinalised(order.inputs, call);
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
            address token = input[0].fromIdentifier();
            uint256 amount = input[1];

            SafeERC20.safeTransfer(IERC20(token), destination, amount);
        }
    }
}
