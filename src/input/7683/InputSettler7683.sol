// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
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

import { MandateERC7683, Order7683Type, StandardOrder } from "./Order7683Type.sol";

/**
 * @title Catalyst Settler supporting The Compact
 * @notice This Catalyst Settler implementation uses The Compact as the deposit scheme.
 * It is a delivery first, inputs second scheme that allows users with a deposit inside The Compact.
 *
 * Users are expected to have an existing deposit inside the Compact or purposefully deposit for the intent.
 * They then needs to either register or sign a supported claim with the intent as the witness.
 * Without the deposit extension, this contract does not have a way to emit on-chain orders.
 *
 * This contract does not support fee on transfer tokens.
 */
contract InputSettler7683 is BaseInputSettler, IInputSettler7683 {
    error NotImplemented();
    error NotOrderOwner();
    error DeadlinePassed();
    error InvalidOrderStatus();
    error InvalidTimestampLength();
    error OrderIdMismatch(bytes32 provided, bytes32 computed);
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
        name = "CatalystEscrow7683";
        version = "7683Escrow1";
    }

    // Generic order identifier
    function orderIdentifier(
        StandardOrder calldata compactOrder
    ) external view returns (bytes32) {
        return Order7683Type.orderIdentifier(compactOrder);
    }

    function orderIdentifier(
        OnchainCrossChainOrder calldata order
    ) external view returns (bytes32) {
        StandardOrder memory compactOrder = Order7683Type.convertToCompactOrder(msg.sender, order);
        return Order7683Type.orderIdentifierMemory(compactOrder);
    }

    function orderIdentifier(
        GaslessCrossChainOrder calldata order
    ) external view returns (bytes32) {
        StandardOrder memory compactOrder = Order7683Type.convertToCompactOrder(order);
        return Order7683Type.orderIdentifierMemory(compactOrder);
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
        OnchainCrossChainOrder calldata order
    ) external {
        // Validate the ERC7683 structure.
        _validateDeadline(order.fillDeadline);

        // Get our orderdata.
        StandardOrder memory compactOrder = Order7683Type.convertToCompactOrder(msg.sender, order);
        bytes32 orderId = Order7683Type.orderIdentifierMemory(compactOrder);

        if (_deposited[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        _deposited[orderId] = OrderStatus.Deposited;

        // Collect input tokens.
        uint256[2][] memory inputs = compactOrder.inputs;
        uint256 numInputs = inputs.length;
        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] memory input = inputs[i];
            address token = EfficiencyLib.asSanitizedAddress(input[0]);
            uint256 amount = input[1];

            SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        }

        emit Open(orderId, _resolve(uint32(0), orderId, compactOrder));
    }

    function _openFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata signature,
        bytes32 orderId,
        StandardOrder memory compactOrder,
        address to
    ) internal {
        ISignatureTransfer.TokenPermissions[] memory permitted;
        ISignatureTransfer.SignatureTransferDetails[] memory transferDetails;

        {
            uint256[2][] memory orderInputs = compactOrder.inputs;
            // Load the number of inputs. We need them to set the array size & convert each
            // input struct into a transferDetails struct.
            uint256 numInputs = orderInputs.length;
            permitted = new ISignatureTransfer.TokenPermissions[](numInputs);
            transferDetails = new ISignatureTransfer.SignatureTransferDetails[](numInputs);
            // Iterate through each input.
            for (uint256 i; i < numInputs; ++i) {
                uint256[2] memory orderInput = orderInputs[i];
                address token = EfficiencyLib.asSanitizedAddress(orderInput[0]);
                uint256 amount = orderInput[1];

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
            nonce: compactOrder.nonce,
            deadline: order.openDeadline
        });
        PERMIT2.permitWitnessTransferFrom(
            permitBatch,
            transferDetails,
            order.user,
            Order7683Type.witnessHash(order, compactOrder),
            string(Order7683Type.PERMIT2_ERC7683_GASLESS_CROSS_CHAIN_ORDER),
            signature
        );
        emit Open(orderId, _resolve(order.openDeadline, orderId, compactOrder));
    }

    function openFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata signature,
        bytes calldata /* originFillerData */
    ) external {
        // Validate the ERC7683 structure.
        _isThisChain(order.originChainId);
        _validateDeadline(order.openDeadline);
        _validateDeadline(order.fillDeadline);

        StandardOrder memory compactOrder = Order7683Type.convertToCompactOrder(order);
        bytes32 orderId = Order7683Type.orderIdentifierMemory(compactOrder);

        if (_deposited[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        _deposited[orderId] = OrderStatus.Deposited;

        // Collect input tokens
        _openFor(order, signature, orderId, compactOrder, address(this));
    }

    function _resolve(
        uint32 openDeadline,
        bytes32 orderId,
        StandardOrder memory compactOrder
    ) internal pure returns (ResolvedCrossChainOrder memory) {
        uint256 chainId = compactOrder.originChainId;

        uint256[2][] memory orderInputs = compactOrder.inputs;
        uint256 numInputs = orderInputs.length;
        // Set input description.
        Output[] memory inputs = new Output[](numInputs);
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] memory orderInput = orderInputs[i];
            uint256 token = orderInput[0];
            uint256 amount = orderInput[1];

            inputs[i] = Output({ token: bytes32(token), amount: amount, recipient: bytes32(0), chainId: chainId });
        }

        MandateOutput[] memory orderOutputs = compactOrder.outputs;
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
            user: compactOrder.user,
            originChainId: compactOrder.originChainId,
            openDeadline: openDeadline,
            fillDeadline: compactOrder.fillDeadline,
            orderId: orderId,
            maxSpent: outputs,
            minReceived: inputs,
            fillInstructions: instructions
        });
    }

    function resolveFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata /* originFillerData */
    ) external view returns (ResolvedCrossChainOrder memory) {
        StandardOrder memory compactOrder = Order7683Type.convertToCompactOrder(order);
        bytes32 orderId = Order7683Type.orderIdentifierMemory(compactOrder);
        return _resolve(order.openDeadline, orderId, compactOrder);
    }

    function resolve(
        OnchainCrossChainOrder calldata order
    ) external view returns (ResolvedCrossChainOrder memory) {
        StandardOrder memory compactOrder = Order7683Type.convertToCompactOrder(msg.sender, order);
        bytes32 orderId = Order7683Type.orderIdentifierMemory(compactOrder);
        return _resolve(uint32(0), orderId, compactOrder);
    }

    //--- Output Proofs ---//

    function _proofPayloadHash(
        bytes32 orderId,
        bytes32 solver,
        uint32 timestamp,
        MandateOutput calldata output
    ) internal pure returns (bytes32 outputHash) {
        return keccak256(MandateOutputEncodingLib.encodeFillDescription(solver, orderId, timestamp, output));
    }

    function _proofPayloadHashM(
        bytes32 orderId,
        bytes32 solver,
        uint32 timestamp,
        MandateOutput memory output
    ) internal pure returns (bytes32 outputHash) {
        return keccak256(MandateOutputEncodingLib.encodeFillDescriptionM(solver, orderId, timestamp, output));
    }

    /**
     * @notice Check if a series of outputs has been proven.
     * @dev Can take a list of solvers. Should be used as a secure alternative to _validateFills
     * if someone filled one of the outputs.
     */
    function _validateFills(
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32[] calldata solvers,
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

    /**
     * @notice Check if a series of outputs has been proven.
     * @dev Notice that the solver of the first provided output is reported as the entire intent solver.
     * This function returns true if the order contains no outputs.
     * That means any order that has no outputs specified can be claimed with no issues.
     */
    function _validateFills(
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32 solver,
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
            bytes32 payloadHash = _proofPayloadHash(orderId, solver, outputFilledAt, output);

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

    function _validateOrderOwner(
        bytes32 orderOwner
    ) internal view {
        // We need to cast orderOwner down. This is important to ensure that
        // the solver can opt-in to an compact transfer instead of withdrawal.
        if (EfficiencyLib.asSanitizedAddress(uint256(orderOwner)) != msg.sender) revert NotOrderOwner();
    }

    function _finalise(StandardOrder calldata order, bytes32 orderId, bytes32 solver, bytes32 destination) internal {
        // Payout inputs. (This also protects against re-entry calls.)
        _resolveLock(orderId, order.inputs, EfficiencyLib.asSanitizedAddress(uint256(destination)));

        emit Finalised(orderId, solver, destination);
    }

    function finaliseSelf(
        StandardOrder calldata order,
        uint32[] calldata timestamps,
        bytes32 solver
    ) external virtual {
        _validateDeadline(order.fillDeadline);
        bytes32 orderId = Order7683Type.orderIdentifier(order);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solver, timestamps);
        _validateOrderOwner(orderOwner);

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solver, timestamps);

        _finalise(order, orderId, solver, orderOwner);
    }

    function finaliseTo(
        StandardOrder calldata order,
        uint32[] calldata timestamps,
        bytes32 solver,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        bytes32 orderId = Order7683Type.orderIdentifier(order);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solver, timestamps);
        _validateOrderOwner(orderOwner);

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solver, timestamps);

        _finalise(order, orderId, solver, destination);
        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else
     * @dev This function serves to finalise intents on the origin chain. It has been assumed that assets have been
     * locked
     * inside The Compact and will be available to collect.
     * To properly collect the order details and proofs, the settler needs the solver identifier and the timestamps of
     * the fills.
     * @param order StandardOrder signed in conjunction with a Compact to form an order.
     */
    function finaliseFor(
        StandardOrder calldata order,
        uint32[] calldata timestamps,
        bytes32 solver,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        bytes32 orderId = Order7683Type.orderIdentifier(order);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solver, timestamps);
        _allowExternalClaimant(
            orderId, EfficiencyLib.asSanitizedAddress(uint256(orderOwner)), destination, call, orderOwnerSignature
        );

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solver, timestamps);

        _finalise(order, orderId, solver, destination);
        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    // -- Fallback Finalise Functions -- //
    // These functions are supposed to be used whenever someone else has filled 1 of the outputs of the order.
    // It allows the proper solver to still resolve the outputs correctly.
    // It does increase the gas cost :(
    // In all cases, the solvers needs to be provided in order of the outputs in order.
    // Important, this output generally matters in regards to the orderId. The solver of the first output is determined
    // to be the "orderOwner".

    function finaliseTo(
        StandardOrder calldata order,
        uint32[] calldata timestamps,
        bytes32[] calldata solvers,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        bytes32 orderId = Order7683Type.orderIdentifier(order);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);
        _validateOrderOwner(orderOwner);

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solvers, timestamps);

        _finalise(order, orderId, solvers[0], destination);
        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else
     * @dev This function serves to finalise intents on the origin chain. It has been assumed that assets have been
     * locked inside The Compact and will be available to collect.
     * To properly collect the order details and proofs, the settler needs the solver identifier and the timestamps of
     * the fills.
     * @param order StandardOrder signed in conjunction with a Compact to form an order.
     */
    function finaliseFor(
        StandardOrder calldata order,
        uint32[] calldata timestamps,
        bytes32[] calldata solvers,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        bytes32 orderId = Order7683Type.orderIdentifier(order);

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solvers, timestamps);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);
        _allowExternalClaimant(
            orderId, EfficiencyLib.asSanitizedAddress(uint256(orderOwner)), destination, call, orderOwnerSignature
        );

        _finalise(order, orderId, solvers[0], destination);
        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    //--- The Compact & Resource Locks ---//

    /**
     * @dev This function employs a local reentry guard: we check the order status and then we update it afterwards. This
     * is an important check as it is indeed to process external ERC20 transfers.
     */
    function _resolveLock(bytes32 orderId, uint256[2][] memory inputs, address solvedBy) internal virtual {
        // Check the order status:
        if (_deposited[orderId] != OrderStatus.Deposited) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        _deposited[orderId] = OrderStatus.Claimed;

        // We have now ensured that this point can only be reached once. We can now process the asset delivery.
        uint256 numInputs = inputs.length;
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] memory input = inputs[i];
            address token = EfficiencyLib.asSanitizedAddress(input[0]);
            uint256 amount = input[1];

            SafeERC20.safeTransfer(IERC20(token), solvedBy, amount);
        }
    }
}
