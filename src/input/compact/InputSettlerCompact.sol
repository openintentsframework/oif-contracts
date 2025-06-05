// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TheCompact } from "the-compact/src/TheCompact.sol";
import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";
import { IdLib } from "the-compact/src/lib/IdLib.sol";
import { BatchClaim } from "the-compact/src/types/BatchClaims.sol";
import { BatchClaimComponent, Component } from "the-compact/src/types/Components.sol";

import { IOpenIntentCallback } from "../../interfaces/IOpenIntentCallback.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

import { IInputSettlerCompact } from "../../interfaces/IInputSettlerCompact.sol";
import { BytesLib } from "../../libs/BytesLib.sol";
import { MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";

import { BaseSettler } from "../BaseSettler.sol";
import { MandateOutput } from "../types/MandateOutputType.sol";
import { OrderPurchase } from "../types/OrderPurchaseType.sol";
import { StandardOrder, StandardOrderType } from "../types/StandardOrderType.sol";

/**
 * @title Catalyst Settler supporting The Compact
 * @notice This Catalyst Settler implementation uses The Compact as the deposit scheme.
 * It is a delivery first, inputs second scheme that allows users with a deposit inside The Compact.
 *
 * Users are expected to have an existing deposit inside the Compact or purposefully deposit for the intent.
 * They then need to either register or sign a supported claim with the intent outputs as the witness.
 * Without the deposit extension, this contract does not have a way to emit on-chain orders.
 *
 * The ownable component of the smart contract is only used for fees.
 */
contract InputSettlerCompact is BaseSettler, IInputSettlerCompact {
    error NotImplemented();
    error NotOrderOwner();
    error InitiateDeadlinePassed();
    error InvalidTimestampLength();
    error OrderIdMismatch(bytes32 provided, bytes32 computed);
    error FilledTooLate(uint32 expected, uint32 actual);
    error WrongChain(uint256 expected, uint256 actual);

    TheCompact public immutable COMPACT;

    constructor(
        address compact
    ) {
        COMPACT = TheCompact(compact);
    }

    /**
     * @notice EIP712
     */
    function _domainNameAndVersion()
        internal
        pure
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "CatalystSettler";
        version = "Compact1";
    }

    // Generic order identifier

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

    //--- Output Proofs ---//

    function _proofPayloadHash(
        bytes32 orderId,
        bytes32 solver,
        uint32 timestamp,
        MandateOutput calldata output
    ) internal pure returns (bytes32 outputHash) {
        return keccak256(MandateOutputEncodingLib.encodeFillDescription(solver, orderId, timestamp, output));
    }

    /**
     * @notice Check if a series of outputs has been proven.
     * @dev Can take a list of solvers. Should be used as a secure alternative to _validateFills
     * if someone filled one of the outputs.
     */
    function _validateFills(
        StandardOrder calldata order,
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
            bytes32 remoteOracle = output.oracle;
            bytes32 remoteFiller = output.settler;
            assembly ("memory-safe") {
                let offset := add(add(proofSeries, 0x20), mul(i, 0x80))
                mstore(offset, chainId)
                mstore(add(offset, 0x20), remoteOracle)
                mstore(add(offset, 0x40), remoteFiller)
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
            bytes32 remoteOracle = output.oracle;
            bytes32 remoteFiller = output.settler;
            assembly ("memory-safe") {
                let offset := add(add(proofSeries, 0x20), mul(i, 0x80))
                mstore(offset, chainId)
                mstore(add(offset, 0x20), remoteOracle)
                mstore(add(offset, 0x40), remoteFiller)
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

    function _finalise(
        StandardOrder calldata order,
        bytes calldata signatures,
        bytes32 orderId,
        bytes32 solver,
        bytes32 destination
    ) internal virtual {
        bytes calldata sponsorSignature = BytesLib.toBytes(signatures, 0x00);
        bytes calldata allocatorData = BytesLib.toBytes(signatures, 0x20);
        // Payout inputs. (This also protects against re-entry calls.)
        _resolveLock(order, sponsorSignature, allocatorData, destination);

        emit Finalised(orderId, solver, destination);
    }

    function finaliseSelf(
        StandardOrder calldata order,
        bytes calldata signatures,
        uint32[] calldata timestamps,
        bytes32 solver
    ) external virtual {
        bytes32 orderId = _orderIdentifier(order);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solver, timestamps);
        _validateOrderOwner(orderOwner);

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solver, timestamps);

        // Deliver outputs before the order has been finalised.
        _finalise(order, signatures, orderId, solver, orderOwner);
    }

    function finaliseTo(
        StandardOrder calldata order,
        bytes calldata signatures,
        uint32[] calldata timestamps,
        bytes32 solver,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        bytes32 orderId = _orderIdentifier(order);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solver, timestamps);
        _validateOrderOwner(orderOwner);

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solver, timestamps);

        // Deliver outputs before the order has been finalised.
        _finalise(order, signatures, orderId, solver, destination);
        if (call.length > 0) {
            IOpenIntentCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).inputsFilled(order.inputs, call);
        }
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else
     * @dev This function serves to finalise intents on the origin chain. It has been assumed that assets have been
     * locked inside The Compact and will be available to collect. To properly collect the order details and proofs,
     * the settler needs the solver identifier and the timestamps of the fills.
     * @param order StandardOrder signed in conjunction with a Compact to form an order.
     * @param signatures A signature for the sponsor and the allocator. abi.encode(bytes(sponsorSignature),
     * bytes(allocatorData))
     */
    function finaliseFor(
        StandardOrder calldata order,
        bytes calldata signatures,
        uint32[] calldata timestamps,
        bytes32 solver,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        bytes32 orderId = _orderIdentifier(order);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solver, timestamps);
        _allowExternalClaimant(
            orderId, EfficiencyLib.asSanitizedAddress(uint256(orderOwner)), destination, call, orderOwnerSignature
        );

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solver, timestamps);

        // Deliver outputs before the order has been finalised.'
        _finalise(order, signatures, orderId, solver, destination);
        if (call.length > 0) {
            IOpenIntentCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).inputsFilled(order.inputs, call);
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
        bytes calldata signatures,
        uint32[] calldata timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        bytes32 orderId = _orderIdentifier(order);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);
        _validateOrderOwner(orderOwner);

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solvers, timestamps);

        // Deliver outputs before the order has been finalised.
        _finalise(order, signatures, orderId, solvers[0], destination);
        if (call.length > 0) {
            IOpenIntentCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).inputsFilled(order.inputs, call);
        }
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else
     * @dev This function serves to finalise intents on the origin chain. It has been assumed that assets have been
     * locked inside The Compact and will be available to collect. To properly collect the order details and proofs,
     * the settler needs the solver identifier and the timestamps of the fills.
     * @param order StandardOrder signed in conjunction with a Compact to form an order.
     * @param signatures A signature for the sponsor and the allocator.
     *  abi.encode(bytes(sponsorSignature), bytes(allocatorData))
     */
    function finaliseFor(
        StandardOrder calldata order,
        bytes calldata signatures,
        uint32[] calldata timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        bytes32 orderId = _orderIdentifier(order);

        // Check if the outputs have been proven according to the oracles.
        // This call will revert if not.
        _validateFills(order, orderId, solvers, timestamps);

        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);
        _allowExternalClaimant(
            orderId, EfficiencyLib.asSanitizedAddress(uint256(orderOwner)), destination, call, orderOwnerSignature
        );

        // Deliver outputs before the order has been finalised.
        _finalise(order, signatures, orderId, solvers[0], destination);
        if (call.length > 0) {
            IOpenIntentCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).inputsFilled(order.inputs, call);
        }
    }

    //--- The Compact & Resource Locks ---//

    function _resolveLock(
        StandardOrder calldata order,
        bytes calldata sponsorSignature,
        bytes calldata allocatorData,
        bytes32 claimant
    ) internal virtual {
        BatchClaimComponent[] memory batchClaimComponents;
        {
            uint256 numInputs = order.inputs.length;
            batchClaimComponents = new BatchClaimComponent[](numInputs);
            uint256[2][] calldata maxInputs = order.inputs;
            for (uint256 i; i < numInputs; ++i) {
                uint256[2] calldata input = maxInputs[i];
                uint256 tokenId = input[0];
                uint256 allocatedAmount = input[1];

                Component[] memory components = new Component[](1);
                components[0] = Component({ claimant: uint256(claimant), amount: allocatedAmount });
                batchClaimComponents[i] = BatchClaimComponent({
                    id: tokenId, // The token ID of the ERC6909 token to allocate.
                    allocatedAmount: allocatedAmount, // The original allocated amount of ERC6909 tokens.
                    portions: components
                });
            }
        }

        require(
            COMPACT.batchClaim(
                BatchClaim({
                    allocatorData: allocatorData,
                    sponsorSignature: sponsorSignature,
                    sponsor: order.user,
                    nonce: order.nonce,
                    expires: order.expires,
                    witness: StandardOrderType.witnessHash(order),
                    witnessTypestring: string(StandardOrderType.BATCH_COMPACT_SUB_TYPES),
                    claims: batchClaimComponents
                })
            ) != bytes32(0)
        );
    }

    // --- Purchase Order --- //

    /**
     * @notice This function is called by whoever wants to buy an order from a filler.
     * If the order was purchased in time, then when the order is settled, the inputs will
     * go to the purchaser instead of the original solver.
     * @dev If you are buying a challenged order, ensure that you have sufficient time to prove the order or
     * your funds may be at risk and that you purchase it within the allocated time.
     * To purchase an order, it is required that you can produce a proper signature
     * from the solver that signs the purchase details.
     * @param orderSolvedByIdentifier Solver of the order. Is not validated, need to be correct otherwise
     * the purchase will be wasted.
     * @param expiryTimestamp Set to ensure if your transaction isn't mine quickly, you don't end
     * up purchasing an order that you cannot prove OR is not within the timeToBuy window.
     */
    function purchaseOrder(
        OrderPurchase calldata orderPurchase,
        StandardOrder calldata order,
        bytes32 orderSolvedByIdentifier,
        bytes32 purchaser,
        uint256 expiryTimestamp,
        bytes calldata solverSignature
    ) external virtual {
        // Sanity check that the user thinks they are buying the right order.
        bytes32 computedOrderId = _orderIdentifier(order);
        if (computedOrderId != orderPurchase.orderId) revert OrderIdMismatch(orderPurchase.orderId, computedOrderId);

        uint256[2][] calldata inputs = order.inputs;
        _purchaseOrder(orderPurchase, inputs, orderSolvedByIdentifier, purchaser, expiryTimestamp, solverSignature);
    }
}
