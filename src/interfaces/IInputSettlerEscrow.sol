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
        StandardOrder memory order,
        uint32[] memory timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes memory call
    ) external;

    function finaliseWithSignature(
        StandardOrder memory order,
        uint32[] memory timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes memory call,
        bytes memory orderOwnerSignature
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
