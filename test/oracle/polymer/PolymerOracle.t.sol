// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { PolymerOracle } from "src/integrations/oracles/polymer/PolymerOracle.sol";
import { MockCrossL2ProverV2 } from "src/integrations/oracles/polymer/external/mocks/MockCrossL2ProverV2.sol";

contract PolymerOracleTest is Test {
    MockCrossL2ProverV2 mockCrossL2ProverV2;
    PolymerOracle polymerOracle;

    function setUp() public {
        mockCrossL2ProverV2 = new MockCrossL2ProverV2();
        polymerOracle = new PolymerOracle(address(mockCrossL2ProverV2));
    }
}
