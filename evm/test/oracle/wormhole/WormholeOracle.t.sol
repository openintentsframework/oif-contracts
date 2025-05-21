// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import { WormholeOracle } from "src/oracles/wormhole/WormholeOracle.sol";

contract WormholeOracleTest is Test {
    WormholeOracle wormholeOracle;

    function setUp() public {
        wormholeOracle = new WormholeOracle(address(this), address(1));
    }

    function test_set_chain_map(uint16 messagingProtocolChainIdentifier, uint256 chainId) external {
        vm.assume(messagingProtocolChainIdentifier != 0);
        vm.assume(chainId != 0);
        wormholeOracle.setChainMap(messagingProtocolChainIdentifier, chainId);

        uint256 readChainId = wormholeOracle.getChainIdentifierToBlockChainId(messagingProtocolChainIdentifier);
        assertEq(readChainId, chainId);

        uint16 readMessagingProtocolChainIdentifier = wormholeOracle.getBlockChainIdToChainIdentifier(chainId);
        assertEq(readMessagingProtocolChainIdentifier, messagingProtocolChainIdentifier);

        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        wormholeOracle.setChainMap(messagingProtocolChainIdentifier, chainId);

        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        wormholeOracle.setChainMap(messagingProtocolChainIdentifier, 1);

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
