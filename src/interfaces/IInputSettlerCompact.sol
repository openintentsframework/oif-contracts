// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { MandateOutput } from "../input/types/MandateOutputType.sol";
import { OrderPurchase } from "../input/types/OrderPurchaseType.sol";
import { StandardOrder } from "../input/types/StandardOrderType.sol";

interface IInputSettlerCompact {
    function finalise(
        StandardOrder memory order,
        bytes memory signatures,
        uint32[] memory timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes memory call
    ) external;

    function finaliseWithSignature(
        StandardOrder memory order,
        bytes memory signatures,
        uint32[] memory timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes memory call,
        bytes memory orderOwnerSignature
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
