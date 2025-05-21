// contracts/Getters.sol
// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "../wormhole/Getters.sol";

contract GettersGetter {
    error WormholeStateAddressZero();

    Getters internal immutable WORMHOLE_STATE;

    constructor(
        address wormholeState
    ) payable {
        if (wormholeState == address(0)) revert WormholeStateAddressZero();
        WORMHOLE_STATE = Getters(wormholeState);
    }

    function getGuardianSet(
        uint32 index
    ) public view returns (Structs.GuardianSet memory) {
        return WORMHOLE_STATE.getGuardianSet(index);
    }

    function getCurrentGuardianSetIndex() public view returns (uint32) {
        return WORMHOLE_STATE.getCurrentGuardianSetIndex();
    }

    function getGuardianSetExpiry() public view returns (uint32) {
        return WORMHOLE_STATE.getGuardianSetExpiry();
    }

    function governanceActionIsConsumed(
        bytes32 hash
    ) public view returns (bool) {
        return WORMHOLE_STATE.governanceActionIsConsumed(hash);
    }

    function isInitialized(
        address impl
    ) public view returns (bool) {
        return WORMHOLE_STATE.isInitialized(impl);
    }

    function chainId() public view returns (uint16) {
        return WORMHOLE_STATE.chainId();
    }

    function evmChainId() public view returns (uint256) {
        return WORMHOLE_STATE.evmChainId();
    }

    function isFork() public view returns (bool) {
        return WORMHOLE_STATE.isFork();
    }

    function governanceChainId() public view returns (uint16) {
        return WORMHOLE_STATE.governanceChainId();
    }

    function governanceContract() public view returns (bytes32) {
        return WORMHOLE_STATE.governanceContract();
    }

    function messageFee() public view returns (uint256) {
        return WORMHOLE_STATE.messageFee();
    }

    function nextSequence(
        address emitter
    ) public view returns (uint64) {
        return WORMHOLE_STATE.nextSequence(emitter);
    }
}
