// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TheCompact } from "the-compact/src/TheCompact.sol";
import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";
import { IdLib } from "the-compact/src/lib/IdLib.sol";
import { BatchMultichainClaim, ExogenousBatchMultichainClaim } from "the-compact/src/types/BatchMultichainClaims.sol";
import { BatchClaimComponent, Component } from "the-compact/src/types/Components.sol";

import { IOIFCallback } from "../../interfaces/IOIFCallback.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

import { BytesLib } from "../../libs/BytesLib.sol";
import { MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";

import { BaseInputSettler } from "../BaseInputSettler.sol";
import { MandateOutput } from "../types/MandateOutputType.sol";

import { MultichainCompactOrderType, MultichainOrderComponent } from "../types/MultichainCompactOrderType.sol";
import { OrderPurchase } from "../types/OrderPurchaseType.sol";

/**
 * @title Input Settler supporting `The Compact` and `MultichainOrderComponent` orders. For `ERC-7683` orders refer to
 * `InputSettler7683`
 * @notice This Input Settler implementation uses The Compact as the deposit scheme. It is a Output first scheme that
 * allows users with a deposit inside The Compact to execute transactions that will be paid **after** the outputs have
 * been proven. This has the advantage that failed orders can be quickly retried. These orders are also entirely gasless
 * since neither valid nor failed transactions does not require any transactions to redeem.
 *
 * Users are expected to have an existing deposit inside the Compact or purposefully deposit for the intent. Then either
 * register or sign a supported claim with the intent outputs as the witness.
 *
 * The contract is intended to be entirely ownerless, permissionlessly deployable, and unstoppable.
 */
contract InputSettlerMultiCompact is BaseInputSettler {
    error UserCannotBeSettler();
    error NotOrderOwner();
    error NoDestination();
    error InvalidTimestampLength();
    error OrderIdMismatch(bytes32 provided, bytes32 computed);
    error FilledTooLate(uint32 expected, uint32 actual);
    error WrongChainId();

    TheCompact public immutable COMPACT;

    constructor(
        address compact
    ) {
        COMPACT = TheCompact(compact);
    }

    /// @notice EIP712
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

    // --- Generic order identifier --- //

    function _orderIdentifier(
        MultichainOrderComponent calldata order
    ) internal pure returns (bytes32) {
        return MultichainCompactOrderType.orderIdentifier(order);
    }

    function orderIdentifier(
        MultichainOrderComponent calldata order
    ) external pure returns (bytes32) {
        return _orderIdentifier(order);
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
     * @param signatures For the signed intent. Is packed: abi.encode(sponsorSignature, allocatorData).
     * @param orderId A unique identifier for the order.
     * @param solver Solver of the outputs.
     * @param destination Destination of the inputs funds signed for by the user.
     * @return orderId Returns a unique global order identifier.
     */
    function _finalise(
        MultichainOrderComponent calldata order,
        bytes calldata signatures,
        bytes32 solver,
        bytes32 destination
    ) internal virtual returns (bytes32 orderId) {
        bytes calldata sponsorSignature = BytesLib.toBytes(signatures, 0x00);
        bytes calldata allocatorData = BytesLib.toBytes(signatures, 0x20);
        orderId = _resolveLock(order, sponsorSignature, allocatorData, destination);
        emit Finalised(orderId, solver, destination);
    }

    /**
     * @notice Finalises an order when called directly by the solver
     * @dev The caller must be the address corresponding to the first solver in the solvers array.
     * @param order MultichainOrderComponent signed in conjunction with a Compact to form an order
     * @param signatures A signature for the sponsor and the allocator. abi.encode(bytes(sponsorSignature),
     * bytes(allocatorData))
     * @param timestamps Array of timestamps when each output was filled
     * @param solvers Array of solvers who filled each output (in order of outputs).
     * @param destination Where to send the inputs. If the solver wants to send the inputs to themselves, they should
     * pass their address to this parameter.
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     */
    function finalise(
        MultichainOrderComponent calldata order,
        bytes calldata signatures,
        uint32[] calldata timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        if (destination == bytes32(0)) revert NoDestination();
        _orderOwnerIsCaller(solvers[0]);

        bytes32 orderId = _finalise(order, signatures, solvers[0], destination);

        _validateFills(order, orderId, solvers, timestamps);

        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else using their signature
     * @dev This function serves to finalise intents on the origin chain with proper authorization from the order owner.
     * @param order MultichainOrderComponent signed in conjunction with a Compact to form an order
     * @param signatures A signature for the sponsor and the allocator. abi.encode(bytes(sponsorSignature),
     * bytes(allocatorData))
     * @param timestamps Array of timestamps when each output was filled
     * @param solvers Array of solvers who filled each output (in order of outputs)
     * element
     * @param destination Where to send the inputs
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     * @param orderOwnerSignature Signature from the order owner authorizing this external call
     */
    function finaliseWithSignature(
        MultichainOrderComponent calldata order,
        bytes calldata signatures,
        uint32[] calldata timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        if (destination == bytes32(0)) revert NoDestination();

        bytes32 orderId = _finalise(order, signatures, solvers[0], destination);

        // Validate the external claimant with signature
        _allowExternalClaimant(
            orderId, EfficiencyLib.asSanitizedAddress(uint256(solvers[0])), destination, call, orderOwnerSignature
        );

        _validateFills(order, orderId, solvers, timestamps);

        if (call.length > 0) {
            IOIFCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    //--- The Compact & Resource Locks ---//

    /**
     * @notice Resolves a Compact Claim for a Standard Order.
     * @param order that should be converted into a Compact Claim.
     * @param sponsorSignature The user's signature for the Compact Claim.
     * @param allocatorData The allocator's signature for the Compact Claim.
     * @param claimant Destination of the inputs funds signed for by the user.
     * @return claimHash The compact claimhash is used as the order identifier, as it is identical for a specific order
     * cross-chain.
     */
    function _resolveLock(
        MultichainOrderComponent calldata order,
        bytes calldata sponsorSignature,
        bytes calldata allocatorData,
        bytes32 claimant
    ) internal virtual returns (bytes32 claimHash) {
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

        address user = order.user;
        // The Compact skips signature checks for msg.sender. Ensure no accidental intents are issued.
        if (user == address(this)) revert UserCannotBeSettler();
        if (true) {
            claimHash = COMPACT.batchMultichainClaim(
                BatchMultichainClaim({
                    allocatorData: allocatorData,
                    sponsorSignature: sponsorSignature,
                    sponsor: user,
                    nonce: order.nonce,
                    expires: order.expires,
                    witness: MultichainCompactOrderType.witnessHash(order),
                    witnessTypestring: string(MultichainCompactOrderType.BATCH_COMPACT_SUB_TYPES),
                    claims: batchClaimComponents,
                    additionalChains: order.additionalChains
                })
            );
        } else {
            claimHash = COMPACT.exogenousBatchClaim(
                ExogenousBatchMultichainClaim({
                    allocatorData: allocatorData,
                    sponsorSignature: sponsorSignature,
                    sponsor: user,
                    nonce: order.nonce,
                    expires: order.expires,
                    witness: MultichainCompactOrderType.witnessHash(order),
                    witnessTypestring: string(MultichainCompactOrderType.BATCH_COMPACT_SUB_TYPES),
                    claims: batchClaimComponents,
                    additionalChains: order.additionalChains,
                    chainIndex: 0,
                    notarizedChainId: 0
                })
            );
        }
    }
}
