// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { MandateOutput } from "../libs/MandateOutputEncodingLib.sol";
import { OrderPurchase } from "../settlers/types/OrderPurchaseType.sol";
import { StandardOrder } from "../settlers/types/StandardOrderType.sol";

interface ISettlerCompact {
    function finaliseFor(
        StandardOrder memory order,
        bytes memory signatures,
        uint32[] memory timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes memory call,
        bytes memory orderOwnerSignature
    ) external;
    function finaliseFor(
        StandardOrder memory order,
        bytes memory signatures,
        uint32[] memory timestamps,
        bytes32 solver,
        bytes32 destination,
        bytes memory call,
        bytes memory orderOwnerSignature
    ) external;
    function finaliseSelf(
        StandardOrder memory order,
        bytes memory signatures,
        uint32[] memory timestamps,
        bytes32 solver
    ) external;
    function finaliseTo(
        StandardOrder memory order,
        bytes memory signatures,
        uint32[] memory timestamps,
        bytes32 solver,
        bytes32 destination,
        bytes memory call
    ) external;
    function finaliseTo(
        StandardOrder memory order,
        bytes memory signatures,
        uint32[] memory timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes memory call
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
