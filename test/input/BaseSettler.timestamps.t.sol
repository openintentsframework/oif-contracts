// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { InputSettlerBase } from "../../src/input/InputSettlerBase.sol";

contract MockSettler is InputSettlerBase {
    function _domainNameAndVersion()
        internal
        pure
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "MockSettler";
        version = "-1";
    }

    function maxTimestamp(
        uint32[] calldata timestamps
    ) external pure returns (uint256 timestamp) {
        return _maxTimestamp(timestamps);
    }

    function minTimestamp(
        uint32[] calldata timestamps
    ) external pure returns (uint256 timestamp) {
        return _minTimestamp(timestamps);
    }
}

contract BaseInputSettlerTestTimestamps is Test {
    MockSettler settler;

    function setUp() public virtual {
        settler = new MockSettler();
    }

    //--- Testing Utility functions ---//

    /// forge-config: default.isolate = true
    function test_max_timestamp() external {
        uint32[] memory timestamp_1 = new uint32[](1);
        timestamp_1[0] = 100;

        assertEq(settler.maxTimestamp(timestamp_1), 100);
        vm.snapshotGasLastCall("inputSettler", "maxTimestamp1");

        uint32[] memory timestamp_5 = new uint32[](5);
        timestamp_5[0] = 1;
        timestamp_5[1] = 5;
        timestamp_5[2] = 1;
        timestamp_5[3] = 5;
        timestamp_5[4] = 6;

        assertEq(settler.maxTimestamp(timestamp_5), 6);

        timestamp_5[0] = 7;
        assertEq(settler.maxTimestamp(timestamp_5), 7);

        timestamp_5[2] = 3;
        assertEq(settler.maxTimestamp(timestamp_5), 7);
    }

    /// forge-config: default.isolate = true
    function test_min_timestamp() external {
        uint32[] memory timestamp_1 = new uint32[](1);
        timestamp_1[0] = 100;

        assertEq(settler.minTimestamp(timestamp_1), 100);
        vm.snapshotGasLastCall("inputSettler", "minTimestamp1");

        uint32[] memory timestamp_5 = new uint32[](5);
        timestamp_5[0] = 1;
        timestamp_5[1] = 5;
        timestamp_5[2] = 1;
        timestamp_5[3] = 5;
        timestamp_5[4] = 6;

        assertEq(settler.minTimestamp(timestamp_5), 1);

        timestamp_5[0] = 7;
        assertEq(settler.minTimestamp(timestamp_5), 1);

        timestamp_5[1] = 0;
        assertEq(settler.minTimestamp(timestamp_5), 0);
    }
}
