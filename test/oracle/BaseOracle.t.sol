// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { BaseInputOracle } from "../../src/oracles/BaseInputOracle.sol";

contract MockBaseInputOracle is BaseInputOracle {
    function setAttestation(
        uint256 remoteChainId,
        bytes32 senderIdentifier,
        bytes32 application,
        bytes32 dataHash
    ) external {
        _attestations[remoteChainId][senderIdentifier][application][dataHash] = true;
    }
}

contract BaseInputOracleTest is Test {
    MockBaseInputOracle baseInputOracle;

    function setUp() external {
        baseInputOracle = new MockBaseInputOracle();
    }

    function test_is_proven(
        uint256 remoteChainId,
        bytes32 application,
        bytes32 remoteOracle,
        bytes32 dataHash
    ) external {
        bool statusBefore = baseInputOracle.isProven(remoteChainId, remoteOracle, application, dataHash);
        assertEq(statusBefore, false);

        baseInputOracle.setAttestation(remoteChainId, remoteOracle, application, dataHash);

        bool statusAfter = baseInputOracle.isProven(remoteChainId, remoteOracle, application, dataHash);
        assertEq(statusAfter, true);
    }

    function test_fuzz_efficientRequireProven(
        bytes calldata proofSeries
    ) external {
        vm.assume(proofSeries.length > 0);
        uint256 lengthOfProofSeriesIn32Chunks = proofSeries.length / (32 * 4);
        lengthOfProofSeriesIn32Chunks *= (32 * 4);
        if (lengthOfProofSeriesIn32Chunks != proofSeries.length) {
            vm.expectRevert(abi.encodeWithSignature("NotDivisible(uint256,uint256)", proofSeries.length, 32 * 4));
        } else {
            vm.expectRevert(abi.encodeWithSignature("NotProven()"));
        }
        baseInputOracle.efficientRequireProven(proofSeries);
    }
}
