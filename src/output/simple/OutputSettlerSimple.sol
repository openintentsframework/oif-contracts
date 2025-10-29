// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { OutputSettlerBase } from "../OutputSettlerBase.sol";

import { MandateOutput } from "../../input/types/MandateOutputType.sol";
import { FillerDataLib } from "./FillerDataLib.sol";
import { FulfilmentLib } from "./FulfilmentLib.sol";

import { Math } from "openzeppelin/utils/math/Math.sol";

/**
 * @notice OutputSettlerSimple extends OutputSettlerBase to support order type-specific resolution logic.
 * @dev This contract implements the `_resolveOutput` function to handle four distinct order types:
 *
 * **Supported Order Types:**
 * - **Limit Orders**: Returns base amount without modification
 * - **Dutch Auctions**: Time-decay pricing using slope parameter
 * - **Exclusive Limit Orders**: Limit orders with solver access restrictions
 * - **Exclusive Dutch Auctions**: Dutch auctions with solver access restrictions
 *
 * Order types are determined by the first byte of context data. Invalid or unsupported order types revert with
 * `NotImplemented()`.
 */
contract OutputSettlerSimple is OutputSettlerBase {
    using FulfilmentLib for bytes;
    using FillerDataLib for bytes;

    /// @dev Order type not implemented
    error NotImplemented();

    /// @dev Exclusive order is attempted by a different solver
    error ExclusiveTo(bytes32 solver);

    /// @dev Proposed solver is zero address
    error ZeroValue();

    /**
     * @dev Executes order specific logic and returns the amount.
     * @param output The `MandateOutput` struct to resolve.
     * @param fillerData The solver data.
     * @return solver The address of the solver filling the output.
     * @return amount The final amount to be transferred (may differ from base amount for Dutch auctions).
     * @dev This function implements order type-specific logic:
     * - Limit orders: Returns the base amount
     * - Dutch auctions: Calculates time-based price using slope
     * - Exclusive orders: Validates solver permissions and returns appropriate amount
     * - Reverts with NotImplemented() for unsupported order types
     *
     * SECURITY WARNING: When orders have multiple outputs, the solver of the first output (the owner) can optimize the
     * filling of the other outputs, which could lead to worse prices for users. The dutch auction order type is
     * vulnerable to this attack.
     * Users should be aware of this risk and avoid this order type in multiple output orders or consider opening
     * orders with exclusivity for trusted solvers.
     */
    function _resolveOutput(
        MandateOutput calldata output,
        bytes calldata fillerData
    ) internal view override returns (bytes32 solver, uint256 amount) {
        amount = output.amount;
        solver = fillerData.solver();
        if (solver == bytes32(0)) revert ZeroValue();

        bytes calldata fulfilmentData = output.context;
        uint16 fulfillmentLength = uint16(fulfilmentData.length);
        if (fulfillmentLength == 0) return (solver, amount);

        bytes1 orderType = fulfilmentData.orderType();
        if (orderType == FulfilmentLib.LIMIT_ORDER) {
            if (fulfillmentLength != 1) revert FulfilmentLib.InvalidContextDataLength();
            return (solver, amount);
        }
        if (orderType == FulfilmentLib.DUTCH_AUCTION) {
            if (fulfillmentLength != 41) revert FulfilmentLib.InvalidContextDataLength();
            (uint32 startTime, uint32 stopTime, uint256 slope) = fulfilmentData.getDutchAuctionData();
            return (solver, _dutchAuctionPrice(amount, slope, startTime, stopTime));
        }
        if (orderType == FulfilmentLib.EXCLUSIVE_LIMIT_ORDER) {
            if (fulfillmentLength != 37) revert FulfilmentLib.InvalidContextDataLength();
            (bytes32 exclusiveFor, uint32 startTime) = fulfilmentData.getExclusiveLimitOrderData();
            if (startTime > block.timestamp && exclusiveFor != solver) revert ExclusiveTo(exclusiveFor);
            return (solver, amount);
        }
        if (orderType == FulfilmentLib.EXCLUSIVE_DUTCH_AUCTION) {
            if (fulfillmentLength != 73) revert FulfilmentLib.InvalidContextDataLength();
            (bytes32 exclusiveFor, uint32 startTime, uint32 stopTime, uint256 slope) =
                fulfilmentData.getExclusiveDutchAuctionData();
            if (startTime > block.timestamp && exclusiveFor != solver) revert ExclusiveTo(exclusiveFor);
            return (solver, _dutchAuctionPrice(amount, slope, startTime, stopTime));
        }
        revert NotImplemented();
    }

    /**
     * @dev Computes the current price of a dutch auction.
     * @dev The auction function is fixed until x=startTime at y=minimumAmount + slope · (stopTime - startTime) then it
     * linearly decreases until x=stopTime at y=minimumAmount which it remains at.
     *  If stopTime <= startTime return minimumAmount.
     * @param minimumAmount After stoptime, this will be the price. The returned amount is never less.
     * @param slope Every second the auction function is decreased by the slope.
     * @param startTime Timestamp when the returned amount begins decreasing. Returns a fixed maximum amount otherwise.
     * @param stopTime Timestamp when the slope stops counting and returns minimumAmount perpetually.
     * @return currentAmount Computed dutch auction amount.
     */
    function _dutchAuctionPrice(
        uint256 minimumAmount,
        uint256 slope,
        uint32 startTime,
        uint32 stopTime
    ) internal view returns (uint256 currentAmount) {
        uint32 currentTime = uint32(Math.max(block.timestamp, uint256(startTime)));
        if (stopTime < currentTime) return minimumAmount; // This check also catches stopTime < startTime.
        uint256 timeDiff;
        unchecked {
            timeDiff = stopTime - currentTime; // unchecked: stopTime > currentTime
        }
        return minimumAmount + slope * timeDiff;
    }
}
