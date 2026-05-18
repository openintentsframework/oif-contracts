// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { MandateOutput } from "../input/types/MandateOutputType.sol";
import { OrderPurchase } from "../input/types/OrderPurchaseType.sol";
import { StandardOrder } from "../input/types/StandardOrderType.sol";

import { InputSettlerBase } from "../input/InputSettlerBase.sol";

interface IInputSettlerCompact {
    function finalise(
        StandardOrder calldata order,
        bytes calldata signatures,
        InputSettlerBase.SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call
    ) external;

    function finaliseWithSignature(
        StandardOrder calldata order,
        bytes calldata signatures,
        InputSettlerBase.SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external;

    function orderIdentifier(
        StandardOrder memory order
    ) external view returns (bytes32);

    function purchaseOrder(
        OrderPurchase memory orderPurchase,
        StandardOrder memory order,
        bytes32 orderSolvedByIdentifier,
        bytes32 purchaser,
        uint256 expiryTimestamp,
        bytes memory solverSignature
    ) external;
}
