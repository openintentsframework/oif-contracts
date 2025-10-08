// SPDX-License-Identifier: MIT
/// @notice this file is copied from
/// https://github.com/LayerZero-Labs/LayerZero-v2/blob/c09287a8b1f236fcc057f474d8a773a0fb7758df/packages/layerzero-v2/evm/protocol/contracts/interfaces/IMessagingContext.sol
pragma solidity >=0.8.0;

interface IMessagingContext {
    function isSendingMessage() external view returns (bool);

    function getSendContext() external view returns (uint32 dstEid, address sender);
}
