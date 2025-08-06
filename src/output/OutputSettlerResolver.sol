// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOutputSettler } from "./BaseOutputSettler.sol";

import { FulfilmentLib } from "../libs/FulfilmentLib.sol";
import { OutputFillLib } from "../libs/OutputFillLib.sol";

contract OutputSettlerResolver is BaseOutputSettler {
    using OutputFillLib for bytes;
    using FulfilmentLib for bytes;

    /**
     * @dev Executes order specific logic and returns the amount.
     * @param output The serialized output data to resolve.
     * @param solver The address of the solver attempting to fill the output.
     * @return amount The final amount to be transferred (may differ from base amount for Dutch auctions).
     * @dev This function implements order type-specific logic:
     * - Limit orders: Returns the base amount
     * - Dutch auctions: Calculates time-based price using slope
     * - Exclusive orders: Validates solver permissions and returns appropriate amount
     * - Reverts with NotImplemented() for unsupported order types
     */
    function _resolveOutput(bytes calldata output, bytes32 solver) internal view override returns (uint256 amount) {
        amount = output.amount();

        bytes calldata fulfilmentData = output.contextData();

        uint16 fulfillmentLength = uint16(fulfilmentData.length);

        if (fulfillmentLength == 0) return amount;

        bytes1 orderType = fulfilmentData.orderType();

        if (orderType == FulfilmentLib.LIMIT_ORDER) {
            if (fulfillmentLength != 1) revert FulfilmentLib.InvalidContextDataLength();
            return amount;
        }
        if (orderType == FulfilmentLib.DUTCH_AUCTION) {
            (uint32 startTime, uint32 stopTime, uint256 slope) = fulfilmentData.getDutchAuctionData();
            return _dutchAuctionSlope(amount, slope, startTime, stopTime);
        }

        if (orderType == FulfilmentLib.EXCLUSIVE_LIMIT_ORDER) {
            (bytes32 exclusiveFor, uint32 startTime) = fulfilmentData.getExclusiveLimitOrderData();
            if (startTime > block.timestamp && exclusiveFor != solver) revert ExclusiveTo(exclusiveFor);
            return amount;
        }
        if (orderType == FulfilmentLib.EXCLUSIVE_DUTCH_AUCTION) {
            (bytes32 exclusiveFor, uint32 startTime, uint32 stopTime, uint256 slope) =
                fulfilmentData.getExclusiveDutchAuctionData();
            if (startTime > block.timestamp && exclusiveFor != solver) revert ExclusiveTo(exclusiveFor);
            return _dutchAuctionSlope(amount, slope, startTime, stopTime);
        }
        revert NotImplemented();
    }
}
