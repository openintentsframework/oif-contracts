// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { InputSettlerBase } from "../../src/input/InputSettlerBase.sol";

import { InputSettlerBase } from "../../src/input/InputSettlerBase.sol";
import { EIP712 } from "openzeppelin/utils/cryptography/EIP712.sol";

contract MockSettler is InputSettlerBase {
    constructor() EIP712("MockSettler", "-1") { }

    function maxTimestamp(
        InputSettlerBase.SolveParams[] calldata solveParams
    ) external pure returns (uint256 timestamp) {
        return _maxTimestamp(solveParams);
    }

    function minTimestamp(
        InputSettlerBase.SolveParams[] calldata solveParams
    ) external pure returns (uint256 timestamp) {
        return _minTimestamp(solveParams);
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
        InputSettlerBase.SolveParams[] memory timestamp_1 = new InputSettlerBase.SolveParams[](1);
        timestamp_1[0] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 100 });

        assertEq(settler.maxTimestamp(timestamp_1), 100);
        vm.snapshotGasLastCall("inputSettler", "maxTimestamp1");

        InputSettlerBase.SolveParams[] memory timestamp_5 = new InputSettlerBase.SolveParams[](5);
        timestamp_5[0] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 1 });
        timestamp_5[1] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 5 });
        timestamp_5[2] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 1 });
        timestamp_5[3] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 5 });
        timestamp_5[4] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 6 });

        assertEq(settler.maxTimestamp(timestamp_5), 6);

        timestamp_5[0] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 7 });
        assertEq(settler.maxTimestamp(timestamp_5), 7);

        timestamp_5[2] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 3 });
        assertEq(settler.maxTimestamp(timestamp_5), 7);
    }

    /// forge-config: default.isolate = true
    function test_min_timestamp() external {
        InputSettlerBase.SolveParams[] memory timestamp_1 = new InputSettlerBase.SolveParams[](1);
        timestamp_1[0] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 100 });

        assertEq(settler.minTimestamp(timestamp_1), 100);
        vm.snapshotGasLastCall("inputSettler", "minTimestamp1");

        InputSettlerBase.SolveParams[] memory timestamp_5 = new InputSettlerBase.SolveParams[](5);
        timestamp_5[0] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 1 });
        timestamp_5[1] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 5 });
        timestamp_5[2] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 1 });
        timestamp_5[3] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 5 });
        timestamp_5[4] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 6 });

        assertEq(settler.minTimestamp(timestamp_5), 1);

        timestamp_5[0] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 7 });
        assertEq(settler.minTimestamp(timestamp_5), 1);

        timestamp_5[1] = InputSettlerBase.SolveParams({ solver: bytes32(0), timestamp: 0 });
        assertEq(settler.minTimestamp(timestamp_5), 0);
    }
}
