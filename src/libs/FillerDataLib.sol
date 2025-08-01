

library FillerDataLib {
    function proposedSolver(bytes calldata fillerData) internal pure returns (bytes32 proposedSolver) {
        assembly ("memory-safe") {
            proposedSolver := calldataload(fillerData.offset)
        }
    }
}