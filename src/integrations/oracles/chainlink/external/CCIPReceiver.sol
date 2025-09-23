// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IAny2EVMMessageReceiver } from "./interfaces/IAny2EVMMessageReceiver.sol";
import { IAny2EVMMessageReceiverV2 } from "./interfaces/IAny2EVMMessageReceiverV2.sol";

import { Client } from "./Client.sol";

import { IERC165 } from "openzeppelin/utils/introspection/IERC165.sol";

/// @title CCIPReceiver - Base contract for CCIP applications that can receive messages.
/// @dev
/// https://github.com/smartcontractkit/chainlink-ccip/blob/632b2acd4f2b203fe4cdd3e93ac0e1303a10ff56/chains/evm/contracts/applications/CCIPReceiver.sol
abstract contract CCIPReceiver is IAny2EVMMessageReceiverV2, IERC165 {
    address internal immutable i_ccipRouter;

    constructor(
        address router
    ) {
        if (router == address(0)) revert InvalidRouter(address(0));
        i_ccipRouter = router;
    }

    /// @notice IERC165 supports an interfaceId.
    /// @param interfaceId The interfaceId to check.
    /// @return true if the interfaceId is supported.
    /// @dev Should indicate whether the contract implements IAny2EVMMessageReceiver.
    /// e.g. return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId
    /// This allows CCIP to check if ccipReceive is available before calling it.
    /// - If this returns false or reverts, only tokens are transferred to the receiver.
    /// - If this returns true, tokens are transferred and ccipReceive is called atomically.
    /// Additionally, if the receiver address does not have code associated with it at the time of
    /// execution (EXTCODESIZE returns 0), only tokens will be transferred.
    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IAny2EVMMessageReceiverV2).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(
        Client.Any2EVMMessage calldata message
    ) external virtual override onlyRouter {
        _ccipReceive(message);
    }

    /// @notice Override this function in your implementation.
    /// @param message Any2EVMMessage.
    function _ccipReceive(
        Client.Any2EVMMessage calldata message
    ) internal virtual;

    /// @notice Return the current router
    /// @return CCIP router address
    function getRouter() public view virtual returns (address) {
        return address(i_ccipRouter);
    }

    /// @notice Return the CCVs required/optional for a source chain.
    /// @dev this can be overridden to specify different CCVs per source chain. The current implementation means the
    /// default CCV is used.
    function getCCVs(
        uint64
    )
        external
        view
        virtual
        returns (address[] memory requiredCCVs, address[] memory optionalCCVs, uint8 optionalThreshold)
    {
        // By default no specific CCVs are required or optional. This means the default CCV is chosen.
        return (new address[](0), new address[](0), 0);
    }

    error InvalidRouter(address router);

    /// @dev only calls from the set router are accepted.
    modifier onlyRouter() {
        if (msg.sender != getRouter()) revert InvalidRouter(msg.sender);
        _;
    }
}
