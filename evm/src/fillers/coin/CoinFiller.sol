// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { MandateOutput, MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";
import { BaseFiller } from "../BaseFiller.sol";

/**
 * @dev Solvers use Oracles to pay outputs. This allows us to record the payment.
 * Tokens never touch this contract but goes directly from solver to user.
 */
contract CoinFiller is BaseFiller {
    error NotImplemented();
    error SlopeStopped();
    error ExclusiveTo(bytes32 solver);

    function _dutchAuctionSlope(
        uint256 amount,
        uint256 slope,
        uint32 startTime,
        uint32 stopTime
    ) internal view returns (uint256 currentAmount) {
        // Select the largest of block.timestamp and start time
        uint32 currentTime = block.timestamp < uint256(startTime) ? startTime : uint32(block.timestamp);
        // If currentTime is past the stopTime then we return the minimum (amount)
        if (stopTime < currentTime) return amount;
        uint256 timeDiff = stopTime - currentTime; // unchecked: stopTime > currentTime
        return amount + slope * timeDiff;
    }

    /**
     * @notice Computes the amount of an order. Allows limit orders and dutch auctions.
     * @dev Uses the fulfillmentContext of the output to determine order type.
     * 0x00 is limit order.             Requires output.fulfillmentContext == 0x00
     * 0x01 is dutch auction.           Requires output.fulfillmentContext == 0x01 | startTime | stopTime | slope
     * 0xe0 is exclusive limit order.   Requires output.fulfillmentContext == 0xe0 | exclusiveFor | startTime
     * 0xe1 is exclusive dutch auction. Requires output.fulfillmentContext == 0x01 | exclusiveFor | startTime | stopTime
     * | slope
     */
    function _getAmount(MandateOutput calldata output, bytes32 proposedSolver) internal view returns (uint256 amount) {
        uint256 fulfillmentLength = output.fulfillmentContext.length;
        if (fulfillmentLength == 0) return output.amount;
        bytes1 orderType = bytes1(output.fulfillmentContext);
        if (orderType == 0x00 && fulfillmentLength == 1) return output.amount;
        if (orderType == 0x01 && fulfillmentLength == 41) {
            bytes calldata fulfillmentContext = output.fulfillmentContext;
            uint32 startTime; // = uint32(bytes4(output.fulfillmentContext[1:5]));
            uint32 stopTime; // = uint32(bytes4(output.fulfillmentContext[5:9]));
            uint256 slope; // = uint256(bytes32(output.fulfillmentContext[9:41]));
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
            bytes calldata fulfillmentContext = output.fulfillmentContext;
            bytes32 exclusiveFor; // = bytes32(bytes32(output.fulfillmentContext[1:33]));
            uint32 startTime; // = uint32(bytes4(output.fulfillmentContext[33:37]));
            assembly ("memory-safe") {
                exclusiveFor := calldataload(add(fulfillmentContext.offset, 1))
                // Clean the leftmost bytes: (32-4)*8 = 224
                startTime := shr(224, shl(224, calldataload(add(fulfillmentContext.offset, 5))))
            }
            if (startTime > block.timestamp && exclusiveFor != proposedSolver) revert ExclusiveTo(exclusiveFor);
            return output.amount;
        }
        if (orderType == 0xe1 && fulfillmentLength == 73) {
            bytes calldata fulfillmentContext = output.fulfillmentContext;
            bytes32 exclusiveFor; // = bytes32(bytes32(output.fulfillmentContext[1:33]));
            uint32 startTime; // = uint32(bytes4(output.fulfillmentContext[33:37]));
            uint32 stopTime; // = uint32(bytes4(output.fulfillmentContext[37:41]));
            uint256 slope; // = uint256(bytes4(output.fulfillmentContext[41:73]));
            assembly ("memory-safe") {
                exclusiveFor := calldataload(add(fulfillmentContext.offset, 1))
                // Clean the leftmost bytes: (32-4)*8 = 224
                startTime := shr(224, shl(224, calldataload(add(fulfillmentContext.offset, 5))))
                stopTime := shr(224, shl(224, calldataload(add(fulfillmentContext.offset, 9))))

                slope := calldataload(add(fulfillmentContext.offset, 41))
            }
            if (startTime > block.timestamp && exclusiveFor != proposedSolver) revert ExclusiveTo(exclusiveFor);
            return _dutchAuctionSlope(output.amount, slope, startTime, stopTime);
        }
        revert NotImplemented();
    }

    function _fill(
        bytes32 orderId,
        MandateOutput calldata output,
        bytes32 proposedSolver
    ) internal override returns (bytes32) {
        uint256 amount = _getAmount(output, proposedSolver);
        return _fill(orderId, output, amount, proposedSolver);
    }
}
