// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.0;

/**
 * @title IProverHelper.sol
 * @author Polymer Labs
 * @notice A contract that exposes Prover helper util functions
 */
interface IProverHelper {
    function packGameID(
        uint32 _gameType,
        uint64 _timestamp,
        address _gameProxy
    ) external pure returns (bytes32 gameId_);

    function rlpEncodeDataLibList(
        bytes[] memory dataList
    ) external pure returns (bytes memory);

    function proveStorage(
        bytes memory _key,
        bytes memory _val,
        bytes[] memory _proof,
        bytes32 _root
    ) external pure;
}
