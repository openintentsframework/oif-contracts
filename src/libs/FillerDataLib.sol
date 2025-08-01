// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


library FillerDataLib {
    function proposedSolver(bytes calldata fillerData) internal pure returns (bytes32 proposedSolver) {
        assembly ("memory-safe") {
            proposedSolver := calldataload(fillerData.offset)
        }
    }
}