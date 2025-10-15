// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "../libs/LibAddress.sol";

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { SignatureChecker } from "openzeppelin/utils/cryptography/SignatureChecker.sol";

import { IInputCallback } from "../interfaces/IInputCallback.sol";

import { AllowOpenType } from "./types/AllowOpenType.sol";
import { MandateOutput } from "./types/MandateOutputType.sol";
import { OrderPurchase, OrderPurchaseType } from "./types/OrderPurchaseType.sol";

import { InputSettlerBase } from "./InputSettlerBase.sol";

/**
 * @title Input Settler Purchase
 * @notice Extends InputSettlerBase with order purchasing functionality that allows third parties to buy orders from
 * solvers.
 * @dev This contract implements order purchasing functionality that enables order ownership transfer from solver to
 * purchaser upon successful purchase. It includes a discount-based pricing mechanism where purchasers pay a reduced
 * amount, EIP712 signature verification for purchase authorization, reentry protection and purchase state tracking, and
 * integration with IInputCallback for post-purchase execution.
 */
abstract contract InputSettlerPurchase is InputSettlerBase {
    using LibAddress for address;
    using LibAddress for bytes32;
    using LibAddress for uint256;

    /**
     * @dev The order has already been purchased.
     */
    error AlreadyPurchased();
    /**
     * @dev The purchase expiry timestamp has passed.
     */
    error Expired();
    /**
     * @dev The purchaser is invalid.
     */
    error InvalidPurchaser();
    /**
     * @dev The caller is not the order owner.
     */
    error NotOrderOwner();

    /**
     * @notice Emitted when an order is purchased.
     * @param orderId The order identifier.
     * @param solver The solver.
     * @param purchaser The purchaser.
     */
    event OrderPurchased(bytes32 indexed orderId, bytes32 solver, bytes32 purchaser);

    uint256 constant DISCOUNT_DENOM = 10 ** 18;

    struct Purchased {
        uint32 lastOrderTimestamp;
        bytes32 purchaser;
    }

    mapping(bytes32 solver => mapping(bytes32 orderId => Purchased)) public purchasedOrders;

    // --- Order Purchase Helpers --- //

    /**
     * @notice Enforces that the caller is the order owner.
     * @dev Only reads the rightmost 20 bytes to verify the owner/purchaser. This allows implementations to use the
     * leftmost 12 bytes to encode further withdrawal logic.
     * For TheCompact, 12 zero bytes indicates a withdrawals instead of a transfer.
     * @param orderOwner The order owner. The leftmost 12 bytes are not read.
     */
    function _orderOwnerIsCaller(
        bytes32 orderOwner
    ) internal view {
        if (orderOwner.fromIdentifier() != msg.sender) revert NotOrderOwner();
    }

    /**
     * @notice Helper function to get the owner of order incase it may have been bought. In case an order has been
     * bought, and bought in time, the owner will be set to the purchaser. Otherwise it will be set to the solver.
     * @param orderId A unique identifier for an order.
     * @param solveParams List of solve parameters for when the outputs were filled.
     * @return orderOwner Owner of the order.
     */
    function _purchaseGetOrderOwner(
        bytes32 orderId,
        SolveParams[] calldata solveParams
    ) internal returns (bytes32 orderOwner) {
        bytes32 solver = solveParams[0].solver;
        Purchased storage purchaseDetails = purchasedOrders[solver][orderId];
        uint32 lastOrderTimestamp = purchaseDetails.lastOrderTimestamp;
        bytes32 purchaser = purchaseDetails.purchaser;

        if (purchaser != bytes32(0)) {
            // We use the last fill (oldest) to gauge if the order was purchased in time.
            uint256 orderTimestamp = _maxTimestamp(solveParams);
            delete purchaseDetails.lastOrderTimestamp;
            delete purchaseDetails.purchaser;
            // If the timestamp is less than or equal to lastOrderTimestamp, the order was purchased in time.
            if (lastOrderTimestamp <= orderTimestamp) return purchaser;
        }
        return solver;
    }

    /**
     * @notice Helper functions for purchasing orders.
     *  @dev The integrating implementation needs to provide the correct orderId and inputs according to the order.
     * @param orderPurchase Order purchase description signed by solver.
     * @param inputs Order inputs that have to be bought.
     * @param orderSolvedByIdentifier Solver of the order. Is not validated.
     * @param purchaser The new order owner.
     * @param expiryTimestamp Set to ensure if your transaction does not mine quickly, you don't end up purchasing an
     * order that you can not prove OR is outside the timeToBuy window.
     * @param solverSignature EIP712 Signature of OrderPurchase by orderOwner.
     */
    function _purchaseOrder(
        OrderPurchase calldata orderPurchase,
        uint256[2][] calldata inputs,
        bytes32 orderSolvedByIdentifier,
        bytes32 purchaser,
        uint256 expiryTimestamp,
        bytes calldata solverSignature
    ) internal {
        if (purchaser == bytes32(0)) revert InvalidPurchaser();
        if (expiryTimestamp < block.timestamp) revert Expired();

        {
            Purchased storage purchased = purchasedOrders[orderSolvedByIdentifier][orderPurchase.orderId];
            if (purchased.purchaser != bytes32(0)) revert AlreadyPurchased();

            // Reentry protection. Ensure that you can't reenter this contract.
            unchecked {
                // unchecked: uint32(block.timestamp) > timeToBuy => uint32(block.timestamp) - timeToBuy > 0.
                uint32 timeToBuy = orderPurchase.timeToBuy;
                purchased.lastOrderTimestamp =
                    timeToBuy < uint32(block.timestamp) ? uint32(block.timestamp) - timeToBuy : 0;
                purchased.purchaser = purchaser; // This disallows reentries through purchased.purchaser != address(0)
            }
            // We can now make external calls without allowing local reentries into this call.
        }

        {
            address orderSolvedByAddress = orderSolvedByIdentifier.fromIdentifier();
            bytes32 digest = _hashTypedDataV4(OrderPurchaseType.hashOrderPurchase(orderPurchase));
            bool isValid = SignatureChecker.isValidSignatureNowCalldata(orderSolvedByAddress, digest, solverSignature);
            if (!isValid) revert InvalidSigner();
        }

        address newDestination = orderPurchase.destination;
        {
            uint256 discount = orderPurchase.discount;
            uint256 numInputs = inputs.length;
            for (uint256 i; i < numInputs; ++i) {
                uint256[2] calldata input = inputs[i];
                uint256 tokenId = input[0];
                uint256 allocatedAmount = input[1];
                uint256 amountAfterDiscount = (allocatedAmount * (DISCOUNT_DENOM - discount)) / DISCOUNT_DENOM;
                // Throws if discount > DISCOUNT_DENOM => DISCOUNT_DENOM - discount < 0;
                SafeERC20.safeTransferFrom(
                    IERC20(tokenId.validatedCleanAddress()), msg.sender, newDestination, amountAfterDiscount
                );
            }
            // Emit the event now because of stack issues.
            emit OrderPurchased(orderPurchase.orderId, orderSolvedByIdentifier, purchaser);
        }
        {
            bytes calldata callData = orderPurchase.callData;
            if (callData.length > 0) IInputCallback(newDestination).orderFinalised(inputs, callData);
        }
    }
}
