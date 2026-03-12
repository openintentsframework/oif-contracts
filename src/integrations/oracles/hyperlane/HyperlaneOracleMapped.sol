// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ChainMap } from "../../../oracles/ChainMap.sol";
import { HyperlaneOracle } from "./HyperlaneOracle.sol";

/**
 * @notice Hyperlane Oracle with mapped chainIds
 */
contract HyperlaneOracleMapped is ChainMap, HyperlaneOracle {
    constructor(
        address _owner,
        address mailbox,
        address customHook,
        address ism
    ) ChainMap(_owner) HyperlaneOracle(mailbox, customHook, ism) { }

    function _getChainId(
        uint256 chainIdentifier
    ) internal view override returns (uint256 chainId) {
        return _getMappedChainId(chainIdentifier);
    }
}
