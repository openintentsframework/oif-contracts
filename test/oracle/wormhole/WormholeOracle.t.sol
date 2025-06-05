// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { WormholeOracle } from "../../../src/oracles/wormhole/WormholeOracle.sol";
import { Test } from "forge-std/Test.sol";

contract WormholeOracleTest is Test {
    WormholeOracle wormholeOracle;

    function setUp() public {
        wormholeOracle = new WormholeOracle(address(this), address(1));
    }

    function test_set_chain_map(uint16 messagingProtocolChainIdentifier, uint256 chainId) external {
        vm.assume(messagingProtocolChainIdentifier != 0);
        vm.assume(chainId != 0);
        wormholeOracle.setChainMap(uint256(messagingProtocolChainIdentifier), chainId);

        uint256 readChainId = wormholeOracle.chainIdMap(uint256(messagingProtocolChainIdentifier));
        assertEq(readChainId, chainId);

        uint16 readMessagingProtocolChainIdentifier = uint16(wormholeOracle.reverseChainIdMap(chainId));
        assertEq(readMessagingProtocolChainIdentifier, messagingProtocolChainIdentifier);

        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        wormholeOracle.setChainMap(uint256(messagingProtocolChainIdentifier), chainId);

        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        wormholeOracle.setChainMap(uint256(messagingProtocolChainIdentifier), 1);

        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        wormholeOracle.setChainMap(1, chainId);
    }

    function test_error_set_chain_map_0() external {
        vm.expectRevert(abi.encodeWithSignature("ZeroValue()"));
        wormholeOracle.setChainMap(0, 0);

        vm.expectRevert(abi.encodeWithSignature("ZeroValue()"));
        wormholeOracle.setChainMap(1, 0);

        vm.expectRevert(abi.encodeWithSignature("ZeroValue()"));
        wormholeOracle.setChainMap(0, 1);

        wormholeOracle.setChainMap(1, 1);
    }
}
