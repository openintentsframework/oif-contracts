// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

error WrongHeaderLength();
error NoBlocksSubmitted();
error BadParent();
error NoParent();
error HashAboveTarget();
error DifficultyRetargetLT25(); // <25% difficulty retarget
error WrongDifficultyBits();
error OldDifficultyPeriod();
error InsufficientTotalDifficulty();
error InsufficientChainLength();
error TooDeepReorg();

/**
 * @notice Tracks Bitcoin. Provides block hashes.
 */
interface IBtcPrism {
    /**
     * @notice Returns the Bitcoin block hash at a specific height.
     */
    function getBlockHash(
        uint256 number
    ) external view returns (bytes32);

    /**
     * @notice Returns the height of the latest block (tip of the chain).
     */
    function getLatestBlockHeight() external view returns (uint256);

    /**
     * @notice Returns the timestamp of the latest block, as Unix seconds.
     */
    function getLatestBlockTime() external view returns (uint256);

    /**
     * @notice Submits a new Bitcoin chain segment (80-byte headers) s
     */
    function submit(
        uint256 blockHeight,
        bytes calldata blockHeaders
    ) external;
}
