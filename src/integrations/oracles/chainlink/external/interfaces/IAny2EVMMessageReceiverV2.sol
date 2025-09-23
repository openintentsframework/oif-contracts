// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IAny2EVMMessageReceiver } from "./IAny2EVMMessageReceiver.sol";

/// @dev
/// https://github.com/smartcontractkit/chainlink-ccip/blob/632b2acd4f2b203fe4cdd3e93ac0e1303a10ff56/chains/evm/contracts/interfaces/IAny2EVMMessageReceiverV2.sol
interface IAny2EVMMessageReceiverV2 is IAny2EVMMessageReceiver {
    function getCCVs(
        uint64 sourceChainSelector
    ) external view returns (address[] memory requiredCCVs, address[] memory optionalCCVs, uint8 optionalThreshold);
}
