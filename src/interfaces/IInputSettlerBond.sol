// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {MandateOutput} from "../input/types/MandateOutputType.sol";
import {OrderPurchase} from "../input/types/OrderPurchaseType.sol";
import {StandardOrder} from "../input/types/StandardOrderType.sol";

import {InputSettlerBase} from "../input/InputSettlerBase.sol";

interface IInputSettlerBond {
    function open(
        StandardOrder calldata order,
        address solver,
        bytes calldata solverSignature
    ) external;

    function finalise(
        StandardOrder calldata order,
        InputSettlerBase.SolveParams[] calldata solveParams
    ) external;

    function refund(StandardOrder calldata order) external;

    function orderIdentifier(
        StandardOrder memory order
    ) external view returns (bytes32);
}
