// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TheCompact } from "the-compact/src/TheCompact.sol";
import { EfficiencyLib } from "the-compact/src/lib/EfficiencyLib.sol";
import { IdLib } from "the-compact/src/lib/IdLib.sol";
import { BatchClaim } from "the-compact/src/types/BatchClaims.sol";
import { BatchClaimComponent, Component } from "the-compact/src/types/Components.sol";

import { IInputCallback } from "../../interfaces/IInputCallback.sol";
import { IInputOracle } from "../../interfaces/IInputOracle.sol";
import { IInputSettlerCompact } from "../../interfaces/IInputSettlerCompact.sol";

import { BytesLib } from "../../libs/BytesLib.sol";
import { MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";

import { MandateOutput } from "../types/MandateOutputType.sol";
import { OrderPurchase } from "../types/OrderPurchaseType.sol";
import { StandardOrder, StandardOrderType } from "../types/StandardOrderType.sol";

import { InputSettlerPurchase } from "../InputSettlerPurchase.sol";

/**
 * @title Input Settler supporting `The Compact` and `StandardOrder` orders. For explicitly escrowed orders refer to
 * `InputSettlerEscrow`
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
contract InputSettlerCompact is InputSettlerPurchase, IInputSettlerCompact {
    error UserCannotBeSettler();
    error OrderIdMismatch(bytes32 provided, bytes32 computed);

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
        name = "OIFCompact";
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

    // --- Finalise Orders --- //

    /**
     * @notice Finalise an order, paying the inputs to the solver.
     * @param order that has been filled.
     * @param signatures For the signed intent. Is packed: abi.encode(sponsorSignature, allocatorData).
     * @param orderId A unique identifier for the order.
     * @param solver Solver of the outputs.
     * @param destination Destination of the inputs funds signed for by the user.
     */
    function _finalise(
        StandardOrder calldata order,
        bytes calldata signatures,
        bytes32 orderId,
        bytes32 solver,
        bytes32 destination
    ) internal virtual {
        bytes calldata sponsorSignature = BytesLib.toBytes(signatures, 0x00);
        bytes calldata allocatorData = BytesLib.toBytes(signatures, 0x20);
        _resolveLock(order, sponsorSignature, allocatorData, destination);
        emit Finalised(orderId, solver, destination);
    }

    /**
     * @notice Finalises an order when called directly by the solver
     * @dev The caller must be the address corresponding to the first solver in the solvers array.
     * @param order StandardOrder signed in conjunction with a Compact to form an order
     * @param signatures A signature for the sponsor and the allocator. abi.encode(bytes(sponsorSignature),
     * bytes(allocatorData))
     * @param timestamps Array of timestamps when each output was filled
     * @param solvers Array of solvers who filled each output (in order of outputs).
     * @param destination Where to send the inputs. If the solver wants to send the inputs to themselves, they should
     * pass their address to this parameter.
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     */
    function finalise(
        StandardOrder calldata order,
        bytes calldata signatures,
        uint32[] calldata timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        _validateDestination(destination);
        _validateInputChain(order.originChainId);

        bytes32 orderId = _orderIdentifier(order);
        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);
        _orderOwnerIsCaller(orderOwner);

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, timestamps, solvers);

        _finalise(order, signatures, orderId, solvers[0], destination);

        if (call.length > 0) {
            IInputCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else using their signature
     * @dev This function serves to finalise intents on the origin chain with proper authorization from the order owner.
     * @param order StandardOrder signed in conjunction with a Compact to form an order
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
        StandardOrder calldata order,
        bytes calldata signatures,
        uint32[] calldata timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        _validateDestination(destination);
        _validateInputChain(order.originChainId);

        bytes32 orderId = _orderIdentifier(order);
        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solvers[0], timestamps);

        // Validate the external claimant with signature
        _allowExternalClaimant(
            orderId, EfficiencyLib.asSanitizedAddress(uint256(orderOwner)), destination, call, orderOwnerSignature
        );

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, timestamps, solvers);

        _finalise(order, signatures, orderId, solvers[0], destination);

        if (call.length > 0) {
            IInputCallback(EfficiencyLib.asSanitizedAddress(uint256(destination))).orderFinalised(order.inputs, call);
        }
    }

    //--- The Compact & Resource Locks ---//

    /**
     * @notice Resolves a Compact Claim for a Standard Order.
     * @param order that should be converted into a Compact Claim.
     * @param sponsorSignature The user's signature for the Compact Claim.
     * @param allocatorData The allocator's signature for the Compact Claim.
     * @param claimant Destination of the inputs funds signed for by the user.
     */
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

        address user = order.user;
        // The Compact skips signature checks for msg.sender. Ensure no accidental intents are issued.
        if (user == address(this)) revert UserCannotBeSettler();
        require(
            COMPACT.batchClaim(
                BatchClaim({
                    allocatorData: allocatorData,
                    sponsorSignature: sponsorSignature,
                    sponsor: user,
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
