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
    function _fill(
        bytes32 orderId,
        bytes calldata output,
        bytes32 proposedSolver
    ) internal override returns (bytes32) {
        uint256 amount = _resolveOutput(output, proposedSolver);
        return _fill(orderId, output, amount, proposedSolver);
    }
}
