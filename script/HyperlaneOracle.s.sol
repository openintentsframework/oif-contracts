// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { HyperlaneOracle } from "../src/integrations/oracles/hyperlane/HyperlaneOracle.sol";

/// @notice Deploys a HyperlaneOracle bound to the chain's Hyperlane Mailbox.
///
/// Deployed with `customHook = address(0)` and `ism = address(0)` so it falls back to the
/// Mailbox's DEFAULT hook and DEFAULT ISM. Do NOT pass a custom ISM/hook address unless you
/// have confirmed it has deployed code on this chain — a codeless ISM silently breaks
/// Hyperlane message verification (delivery never completes).
///
/// Uses CREATE2 (`salt: bytes32(0)`), matching script/WormholeOracle.s.sol. The address is
/// determined by the CREATE2 factory + salt + bytecode + constructor args, so it is deterministic
/// PER CHAIN but NOT shared across chains (the `mailbox` arg differs per chain). Dry-run each chain
/// to record its predicted address before broadcasting.
///
/// Usage:
///   forge script script/HyperlaneOracle.s.sol:DeployHyperlaneOracle \
///     --sig 'deploy(address)' <MAILBOX> \
///     --rpc-url <RPC> --account deployer --broadcast
contract DeployHyperlaneOracle is Script {
    function deploy(
        address mailbox
    ) external returns (HyperlaneOracle oracle) {
        require(mailbox != address(0), "mailbox=0");

        vm.broadcast();
        oracle = new HyperlaneOracle{ salt: bytes32(0) }(mailbox, address(0), address(0));
    }
}
