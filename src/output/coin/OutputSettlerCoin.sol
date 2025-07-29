// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";
import { BaseOutputSettler } from "../BaseOutputSettler.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/**
 * @notice Output Settler for ERC20 tokens.
 * Does not support native coins.
 * This contract supports 4 order types:
 * - Limit Order & Exclusive Limit Orders
 * - Dutch Auctions & Exclusive Dutch Auctions
 * Exclusive orders has a period in the beginning of the order where it can only be filled by a specific solver.
 * @dev Tokens never touch this contract but goes directly from solver to user.
 */
contract OutputSettlerCoin is BaseOutputSettler {
    error NotImplemented();
    error ExclusiveTo(bytes32 solver);

    /**
     * @notice Computes a dutch auction slope.
     * @dev The auction function is fixed until x=startTime at y=minimumAmount + slope · (stopTime - startTime) then it
     * linearly decreases until x=stopTime at y=minimumAmount which it remains at.
     *  If stopTime <= startTime return minimumAmount.
     * @param minimumAmount After stoptime, this will be the price. The returned amount is never less.
     * @param slope Every second the auction function is decreased by the slope.
     * @param startTime Timestamp when the returned amount begins decreasing. Returns a fixed maximum amount otherwise.
     * @param stopTime Timestamp when the slope stops counting and returns minimumAmount perpetually.
     * @return currentAmount Computed dutch auction amount.
     */
    function _dutchAuctionSlope(
        uint256 minimumAmount,
        uint256 slope,
        uint32 startTime,
        uint32 stopTime
    ) internal view returns (uint256 currentAmount) {
        uint32 currentTime = uint32(FixedPointMathLib.max(block.timestamp, uint256(startTime)));
        if (stopTime < currentTime) return minimumAmount; // This check also catches stopTime < startTime.

        uint256 timeDiff;
        unchecked {
            timeDiff = stopTime - currentTime; // unchecked: stopTime > currentTime
        }
        return minimumAmount + slope * timeDiff;
    }

    /**
     * @notice Executes order specific logic and returns the amount.
     * @dev Uses output.context to determine order type.
     * 0x00: limit order             : B1:orderType
     * 0x01: dutch auction           : B1:orderType | B4:startTime     | B4:stopTime  | B32:slope
     * 0xe0: exclusive limit order   : B1:orderType | B32:exclusiveFor | B4:startTime
     * 0xe1: exclusive dutch auction : B1:orderType | B32:exclusiveFor | B4:startTime | B4:stopTime | B32:slope
     * For exclusive orders, reverts if before startTime and solver is not exclusiveFor.
     * @param output Output to evaluate.
     * @param proposedSolver Solver identifier to be compared against exclusiveFor for exclusive orders.
     * @return amount The computed amount for the output.
     */
    function _resolveOutput(
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) internal view override returns (uint256 amount) {
        uint256 fulfillmentLength = output.context.length;
        if (fulfillmentLength == 0) return output.amount;
        bytes1 orderType = bytes1(output.context);
        if (orderType == 0x00 && fulfillmentLength == 1) return output.amount;
        if (orderType == 0x01 && fulfillmentLength == 41) {
            bytes calldata fulfillmentContext = output.context;
            uint32 startTime; // = uint32(bytes4(output.context[1:5]));
            uint32 stopTime; // = uint32(bytes4(output.context[5:9]));
            uint256 slope; // = uint256(bytes32(output.context[9:41]));
            assembly ("memory-safe") {
                // Shift startTime into the rightmost 4 bytes: (32-4)*8 = 224
                startTime := shr(224, calldataload(add(fulfillmentContext.offset, 1)))
                // Clean leftmost 4 bytes and shift stoptime into the rightmost 4 bytes.
                stopTime := shr(224, calldataload(add(fulfillmentContext.offset, 5)))
                slope := calldataload(add(fulfillmentContext.offset, 9))
            }
            return _dutchAuctionSlope(output.amount, slope, startTime, stopTime);
        }

        if (orderType == 0xe0 && fulfillmentLength == 37) {
            bytes calldata fulfillmentContext = output.context;
            bytes32 exclusiveFor; // = bytes32(output.context[1:33]);
            uint32 startTime; // = uint32(bytes4(output.context[33:37]));
            assembly ("memory-safe") {
                exclusiveFor := calldataload(add(fulfillmentContext.offset, 1))
                // Clean the leftmost bytes: (32-4)*8 = 224
                startTime := shr(224, calldataload(add(fulfillmentContext.offset, 33)))
            }
            if (startTime > block.timestamp && exclusiveFor != proposedSolver) revert ExclusiveTo(exclusiveFor);
            return output.amount;
        }
        if (orderType == 0xe1 && fulfillmentLength == 73) {
            bytes calldata fulfillmentContext = output.context;
            bytes32 exclusiveFor; // = bytes32(output.context[1:33]);
            uint32 startTime; // = uint32(bytes4(output.context[33:37]));
            uint32 stopTime; // = uint32(bytes4(output.context[37:41]));
            uint256 slope; // = uint256(bytes4(output.context[41:73]));
            assembly ("memory-safe") {
                exclusiveFor := calldataload(add(fulfillmentContext.offset, 1))
                // Clean the leftmost bytes: (32-4)*8 = 224
                startTime := shr(224, calldataload(add(fulfillmentContext.offset, 33)))
                stopTime := shr(224, calldataload(add(fulfillmentContext.offset, 37)))

                slope := calldataload(add(fulfillmentContext.offset, 41))
            }
            if (startTime > block.timestamp && exclusiveFor != proposedSolver) revert ExclusiveTo(exclusiveFor);
            return _dutchAuctionSlope(output.amount, slope, startTime, stopTime);
        }
        revert NotImplemented();
    }
}
