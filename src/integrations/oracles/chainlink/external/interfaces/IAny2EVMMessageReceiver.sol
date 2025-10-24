// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Client } from "../Client.sol";

/// @notice Application contracts that intend to receive messages from the router should implement this interface.
/// @dev
/// https://github.com/smartcontractkit/chainlink-ccip/blob/632b2acd4f2b203fe4cdd3e93ac0e1303a10ff56/chains/evm/contracts/interfaces/IAny2EVMMessageReceiver.sol
interface IAny2EVMMessageReceiver {
    /// @notice Called by the Router to deliver a message. If this reverts, any token transfers also revert.
    /// The message will move to a FAILED state and become available for manual execution.
    /// @param message CCIP Message.
    /// @dev Note ensure you check the msg.sender is the OffRampRouter.
    function ccipReceive(
        Client.Any2EVMMessage calldata message
    ) external;
}
