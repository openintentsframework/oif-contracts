// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { MandateOutput } from "../input/types/MandateOutputType.sol";
import { OrderPurchase } from "../input/types/OrderPurchaseType.sol";
import { StandardOrder } from "../input/types/StandardOrderType.sol";

interface IInputSettlerEscrow {
    function openFor(bytes calldata order, address sponsor, bytes calldata signature) external;

    function open(
        bytes calldata order
    ) external;

    function finalise(
        StandardOrder calldata order,
        uint32[] calldata timestamps,
        bytes32[] calldata solvers,
        bytes32 destination,
        bytes calldata call
    ) external;

    function finaliseWithSignature(
        StandardOrder calldata order,
        uint32[] calldata timestamps,
        bytes32[] calldata solvers,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external;

    function orderIdentifier(
        bytes memory order
    ) external view returns (bytes32);

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
