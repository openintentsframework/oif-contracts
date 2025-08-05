// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Library to extract the fields of filler data to their respective types.
 * @dev This library provides low-level parsing functions for filler data that has been encoded
 * using a specific byte layout.
 *
 * @dev Bytes Layout
 * The serialized filler data follows this exact byte layout:
 *
 * PROPOSED_SOLVER       0               (32 bytes)  - bytes32: proposed solver address
 */
library FillerDataLib {
    /**
     * @notice Loads the proposed solver from the filler data.
     * @param fillerData Serialised filler data.
     * @return _proposedSolver Proposed solver associated with the filler data.
     */
    function proposedSolver(
        bytes calldata fillerData
    ) internal pure returns (bytes32 _proposedSolver) {
        assembly ("memory-safe") {
            _proposedSolver := calldataload(fillerData.offset)
        }
    }
}
