// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { OrderPurchase } from "../input/types/OrderPurchaseType.sol";
import { StandardOrder } from "../input/types/StandardOrderType.sol";
import { MandateOutput } from "../libs/MandateOutputEncodingLib.sol";
import { GaslessCrossChainOrder, OnchainCrossChainOrder, ResolvedCrossChainOrder } from "./IERC7683.sol";

interface IInputSettler7683 {
    function finaliseFor(
        StandardOrder memory order,
        uint32[] memory timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes memory call,
        bytes memory orderOwnerSignature
    ) external;
    function finaliseFor(
        StandardOrder memory order,
        uint32[] memory timestamps,
        bytes32 solver,
        bytes32 destination,
        bytes memory call,
        bytes memory orderOwnerSignature
    ) external;
    function finaliseSelf(StandardOrder memory order, uint32[] memory timestamps, bytes32 solver) external;
    function finaliseTo(
        StandardOrder memory order,
        uint32[] memory timestamps,
        bytes32 solver,
        bytes32 destination,
        bytes memory call
    ) external;
    function finaliseTo(
        StandardOrder memory order,
        uint32[] memory timestamps,
        bytes32[] memory solvers,
        bytes32 destination,
        bytes memory call
    ) external;
    function open(
        OnchainCrossChainOrder memory order
    ) external;
    function openFor(GaslessCrossChainOrder memory order, bytes memory signature, bytes memory) external;
    function orderIdentifier(
        OnchainCrossChainOrder memory order
    ) external view returns (bytes32);
    function orderIdentifier(
        StandardOrder memory compactOrder
    ) external view returns (bytes32);
    function orderIdentifier(
        GaslessCrossChainOrder memory order
    ) external view returns (bytes32);
    function resolve(
        OnchainCrossChainOrder memory order
    ) external view returns (ResolvedCrossChainOrder memory);
    function resolveFor(
        GaslessCrossChainOrder memory order,
        bytes memory
    ) external view returns (ResolvedCrossChainOrder memory);
}
