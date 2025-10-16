// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { Endian } from "./Endian.sol";
import "./interfaces/IBtcPrism.sol";

// BtcPrism lets you prove that a Bitcoin transaction executed, on Ethereum. It
// does this by running an on-chain light client.
//
// Anyone can submit block headers to BtcPrism. The contract verifies
// proof-of-work, keeping only the longest chain it has seen. As long as 50% of
// Bitcoin hash power is honest and at least one person is running the submitter
// script, the BtcPrism contract always reports the current canonical Bitcoin
// chain.
contract BtcPrism is IBtcPrism {
    /**
     * @notice Emitted whenever the contract accepts a new heaviest chain.
     */
    event NewTip(uint256 blockHeight, uint256 blockTime, bytes32 blockHash);

    /**
     * @notice Emitted only after a difficulty retarget, when the contract
     *         accepts a new heaviest chain with updated difficulty.
     */
    event NewTotalDifficultySinceRetarget(uint256 blockHeight, uint256 totalDifficulty, uint32 newDifficultyBits);

    /**
     * @notice Emitted when we reorg out a portion of the chain.
     */
    event Reorg(uint256 count, bytes32 oldTip, bytes32 newTip);

    uint120 private latestBlockTime;

    uint120 private latestBlockHeight;

    /**
     * @notice Whether we're tracking testnet or mainnet Bitcoin.
     */
    bool public immutable isTestnet;

    /**
     * @notice Store the last 2n blocks. Reorgs deeper than n are unsupported.
     * (For comparison, the deepest Bitcoin reorg so far was 53 blocks in Aug
     * 2010, and anything over 5 blocks would be considered catastrophic today.)
     * Storing only the last n blocks saves ~17,000 gas per block.
     */
    // 1000 blocks is: 10000 minutes = 166 hours = 6.9 days.
    uint256 constant MAX_ALLOWED_REORG = 1000;
    uint256 constant NUM_BLOCKS = 2000;
    bytes32[NUM_BLOCKS] public blockHashes;

    /**
     * @notice Difficulty targets in each retargeting period.
     */
    mapping(uint256 => uint256) public periodToTarget;

    /**
     * @notice Tracks Bitcoin starting from a given block. The isTestnet
     *          argument is necessary because the Bitcoin testnet does not
     *          respect the difficulty rules, so we disable block difficulty
     *          checks in order to track it.
     */
    constructor(
        uint120 _blockHeight,
        bytes32 _blockHash,
        uint120 _blockTime,
        uint256 _expectedTarget,
        bool _isTestnet
    ) {
        require(_blockHeight > 2016); // Is needed for unchecked math.

        blockHashes[_blockHeight % NUM_BLOCKS] = _blockHash;
        latestBlockHeight = _blockHeight;
        latestBlockTime = _blockTime;
        periodToTarget[_blockHeight / 2016] = _expectedTarget;
        isTestnet = _isTestnet;
    }

    /**
     * @notice Returns the Bitcoin block hash at a specific height.
     * The block number must not be higher than getLatestBlockHeight().
     * Returns 0 if the block is too old, and we no longer store its hash.
     */
    function getBlockHash(
        uint256 blockNum
    ) public view returns (bytes32) {
        require(blockNum <= latestBlockHeight, "Block not yet submitted");
        if (blockNum < latestBlockHeight - MAX_ALLOWED_REORG) return 0;
        return blockHashes[blockNum % NUM_BLOCKS];
    }

    /**
     * @notice Returns the height of the current chain tip.
     */
    function getLatestBlockHeight() public view returns (uint256) {
        return latestBlockHeight;
    }

    /**
     * @notice Returns the timestamp of the current chain tip.
     */
    function getLatestBlockTime() public view returns (uint256) {
        return latestBlockTime;
    }

    /**
     * Submits a new Bitcoin chain segment. Must be heavier (not necessarily
     * longer) than the chain rooted at getBlockHash(getLatestBlockHeight()).
     */
    function submit(
        uint256 blockHeight,
        bytes calldata blockHeaders
    ) public {
        unchecked {
            require(blockHeight > 2016); // Is needed for unchecked math.

            uint256 numHeaders = blockHeaders.length / 80;
            if (numHeaders * 80 != blockHeaders.length) revert WrongHeaderLength();
            if (numHeaders == 0) revert NoBlocksSubmitted();
            if (blockHeight <= latestBlockHeight - MAX_ALLOWED_REORG) revert TooDeepReorg();

            // sanity check: the new chain must not end in a past difficulty period
            uint256 oldPeriod = latestBlockHeight / 2016;
            uint256 newHeight = blockHeight + numHeaders - 1; // unchecked: numHeaders is at least 1 and 1-1 = 0.
            uint256 newPeriod = newHeight / 2016;
            if (newPeriod < oldPeriod) revert OldDifficultyPeriod();

            // if we crossed a retarget, do extra math to compare chain weight
            uint256 parentPeriod = (blockHeight - 1) / 2016; // unchecked: blockHeight is at least 1.
            uint256 oldWork = 0;
            if (newPeriod > parentPeriod) {
                require(newPeriod == parentPeriod + 1); // unchecked: parentPeriod is max uint256/2016 <
                    // type(uint256).max
                    // the submitted chain segment contains a difficulty retarget.
                if (newPeriod == oldPeriod) {
                    // the old canonical chain is past the retarget
                    // we cannot compare length, we must compare total work
                    oldWork = getWorkInPeriod(oldPeriod, latestBlockHeight);
                } else {
                    // the old canonical chain is before the retarget
                    require(oldPeriod == parentPeriod);
                }
            }

            // verify and store each block
            bytes32 oldTip = getBlockHash(latestBlockHeight);
            uint256 nReorg = latestBlockHeight - blockHeight;
            for (uint256 i = 0; i < numHeaders; ++i) {
                // unchecked: This might overflow if numheaders = type(uint256).max - type(uint256).max/2016. But that
                // is such a massive number
                // that it is not going to overflow.
                uint256 blockNum = blockHeight + i;
                submitBlock(blockNum, blockHeaders[80 * i:80 * (i + 1)]); // unchecked: Overflows if blockHeaders.length
                    // == type(uint256).max.
            }

            // check that we have a new heaviest chain
            if (newPeriod > parentPeriod) {
                // the submitted chain segment crosses into a new difficulty
                // period. this is happens once every ~2 weeks. check total work
                bytes calldata lastHeader = blockHeaders[80 * (numHeaders - 1):]; // unchecked: won't overflow since
                    // numHeaders*80 is bounded by type(uint256).max
                uint32 newDifficultyBits = Endian.reverse32(uint32(bytes4(lastHeader[72:76])));

                uint256 newWork = getWorkInPeriod(newPeriod, newHeight);
                if (newWork <= oldWork) revert InsufficientTotalDifficulty();

                // erase any block hashes above newHeight, now invalidated.
                // (in case we just accepted a shorter, heavier chain.)
                for (uint256 i = newHeight + 1; i <= latestBlockHeight; ++i) {
                    blockHashes[i % NUM_BLOCKS] = 0;
                }

                emit NewTotalDifficultySinceRetarget(newHeight, newWork, newDifficultyBits);
            } else {
                // here we know what newPeriod == oldPeriod == parentPeriod
                // with identical per-block difficulty. just keep the longest chain.
                require(newPeriod == oldPeriod);
                require(newPeriod == parentPeriod);
                if (newHeight <= latestBlockHeight) revert InsufficientChainLength();
            }

            // record the new tip height and timestamp
            latestBlockHeight = uint120(newHeight);
            uint256 ixT = blockHeaders.length - 12; // blockHeaders.length is at least 80.
            uint32 time = uint32(bytes4(blockHeaders[ixT:ixT + 4])); // max ixT = type(uint256).max - 12 => max ixT +4
                // => type(uint256).max - 12 + 4
            latestBlockTime = Endian.reverse32(time);

            // finally, log the new tip
            bytes32 newTip = getBlockHash(newHeight);
            emit NewTip(newHeight, latestBlockTime, newTip);
            if (nReorg > 0) emit Reorg(nReorg, oldTip, newTip);
        }
    }

    function getWorkInPeriod(
        uint256 period,
        uint256 height
    ) private view returns (uint256) {
        unchecked {
            uint256 target = periodToTarget[period];
            // unchecked: The maximum target is around 2^224 < 2**256
            // ~target / (target + 1) is type(uint256).max if target == 0
            // but target > 1 => ~target / (target + 1) < type(uint256).max
            // => ~target / (target + 1) + 1 <= type(uint256).max
            // Target >= 1 is checked on the bitcoin level.
            uint256 workPerBlock = ~target / (target + 1) + 1;

            // unchecked: period is not raw from input but parsed as newHeight/2016.
            // as such, we can multiply it by 2016.
            uint256 numBlocks = height - (period * 2016) + 1;
            require(numBlocks >= 1 && numBlocks <= 2016);

            return numBlocks * workPerBlock;
        }
    }

    function submitBlock(
        uint256 blockHeight,
        bytes calldata blockHeader
    ) private {
        unchecked {
            require(blockHeight > 2016);

            // compute the block hash
            require(blockHeader.length == 80);
            uint256 blockHashNum = Endian.reverse256(uint256(sha256(bytes.concat(sha256(blockHeader)))));

            // optimistically save the block hash
            // we'll revert if the header turns out to be invalid.
            // this is the most expensive line. 20,000 gas to use a new storage slot
            blockHashes[blockHeight % NUM_BLOCKS] = bytes32(blockHashNum);

            // verify previous hash
            bytes32 prevHash = bytes32(Endian.reverse256(uint256(bytes32(blockHeader[4:36]))));
            // Add NUM_BLOCKS so we roll over then subtract one so we go down.
            if (prevHash != blockHashes[(blockHeight + NUM_BLOCKS - 1) % NUM_BLOCKS]) revert BadParent(); // unchecked:
                // blockHeight >= 1
            if (prevHash == bytes32(0)) revert NoParent();

            // verify proof-of-work
            bytes32 bits = bytes32(blockHeader[72:76]);
            uint256 target = getTarget(bits);
            if (blockHashNum >= target) revert HashAboveTarget();

            // support once-every-2016-blocks retargeting
            uint256 period = blockHeight / 2016;
            if (blockHeight % 2016 == 0) {
                // Bitcoin enforces a minimum difficulty of 25% of the previous
                // difficulty. Doing the full calculation here does not necessarily
                // add any security. We keep the heaviest chain, not the longest.
                uint256 lastTarget = periodToTarget[period - 1]; // blockHeight > 2016 => blockHeight / 2016 > 1 =>
                    // fine.
                    // ignore difficulty update rules on testnet.
                    // Bitcoin testnet has some clown hacks regarding difficulty, see
                    // https://blog.lopp.net/the-block-storms-of-bitcoins-testnet/
                if (!isTestnet) {
                    if (target >> 2 >= lastTarget) revert DifficultyRetargetLT25();
                    if (target << 2 <= lastTarget) revert DifficultyRetargetLT25();
                }
                periodToTarget[period] = target;
            } else if (!isTestnet) {
                // verify difficulty
                if (target != periodToTarget[period]) revert WrongDifficultyBits();
            }
        }
    }

    function getTarget(
        bytes32 bits
    ) public pure returns (uint256) {
        // Bitcoin represents difficulty using a custom floating-point big int
        // representation. the "difficulty bits" consist of an 8-bit exponent
        // and a 24-bit mantissa, which combine to generate a u256 target. the
        // block hash must be below the target.
        uint256 exp = uint8(bits[3]);
        uint256 mantissa = uint8(bits[2]);
        mantissa = (mantissa << 8) | uint8(bits[1]);
        mantissa = (mantissa << 8) | uint8(bits[0]);
        uint256 target = mantissa << (8 * (exp - 3));
        return target;
    }
}
