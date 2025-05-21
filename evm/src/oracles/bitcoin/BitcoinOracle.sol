// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Endian } from "bitcoinprism-evm/src/Endian.sol";
import { IBtcPrism } from "bitcoinprism-evm/src/interfaces/IBtcPrism.sol";
import { NoBlock, TooFewConfirmations } from "bitcoinprism-evm/src/interfaces/IBtcTxVerifier.sol";
import { BtcProof, BtcTxProof, ScriptMismatch } from "bitcoinprism-evm/src/library/BtcProof.sol";
import { AddressType, BitcoinAddress, BtcScript } from "bitcoinprism-evm/src/library/BtcScript.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { MandateOutput, MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";

import { BaseOracle } from "../BaseOracle.sol";

/**
 * @dev Bitcoin oracle can operate in 2 modes:
 * 1. Directly Oracle. This requires a local light client along side the relevant reactor.
 * 2. Indirectly oracle through a bridge oracle.
 * This requires a local light client and a bridge connection to the relevant reactor.
 *
 * This oracle only works on EVM since it requires the original order to compute an orderID
 * which is used for the optimistic content.
 *
 * This filler can work as both an oracle
 * 0xB17C012
 */
contract BitcoinOracle is BaseOracle {
    error AlreadyClaimed(bytes32 claimer);
    error AlreadyDisputed(address disputer);
    error AmountTooLarge();
    error BadAmount(); // 0x749b5939
    error BadTokenFormat(); // 0x6a6ba82d
    error BlockhashMismatch(bytes32 actual, bytes32 proposed); // 0x13ffdc7d
    error Disputed();
    error NotClaimed();
    error NotDisputed();
    error OrderIdMismatch(bytes32 provided, bytes32 computed);
    error TooEarly();
    error TooLate();
    error ZeroValue(); // 0x7c946ed7

    /**
     * @dev WARNING! Don't read output.remoteOracle nor output.chainId when emitted by this oracle.
     */
    event OutputFilled(bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output);
    event OutputVerified(bytes32 verificationContext);

    event OutputClaimed(bytes32 indexed orderId, bytes32 outputId);
    event OutputDisputed(bytes32 indexed orderId, bytes32 outputId);
    event OutputOptimisticallyVerified(bytes32 indexed orderId, bytes32 outputId);
    event OutputDisputeFinalised(bytes32 indexed orderId, bytes32 outputId);

    // Is 3 storage slots.
    struct ClaimedOrder {
        bytes32 solver;
        uint32 claimTimestamp;
        uint64 multiplier;
        address sponsor;
        address disputer;
        /**
         * @notice For a claim to payout to the sponsor, it is required that the input was included before this
         * timestamp.
         * For disputers, note that it is possible to set the inclusion timestamp to 1 block prior.
         * @dev Is the maximum of (block.timestamp and claimTimestamp + MIN_TIME_FOR_INCLUSION)
         */
        uint32 disputeTimestamp;
    }

    mapping(bytes32 orderId => mapping(bytes32 outputId => ClaimedOrder)) public _claimedOrder;

    // The Bitcoin Identifier (0xBC) is set in the 20'th byte (from right). This ensures
    // implementations that are only reading the last 20 bytes, still notice this is a Bitcoin address.
    // It also makes it more difficult for there to be a collision (even though low numeric value
    // addresses are generally pre-compiles and thus would be safe).
    // This also standardizes support for other light clients coins (Lightcoin 0x1C?)
    bytes30 constant BITCOIN_AS_TOKEN = 0x000000000000000000000000BC0000000000000000000000000000000000;

    /**
     * @notice Used light client. If the contract is not overwritten, it is expected to be BitcoinPrism.
     */
    address public immutable LIGHT_CLIENT;
    /**
     * @notice The purpose of the dispute fee is to make sure that 1 person can't claim and dispute the transaction at
     * no risk.
     */
    address public immutable DISPUTED_ORDER_FEE_DESTINATION;
    uint256 public constant DISPUTED_ORDER_FEE_FRACTION = 3;

    /**
     * @notice Require that the challenger provides X times the collateral of the claimant.
     */
    uint256 public constant CHALLENGER_COLLATERAL_FACTOR = 2;

    address public immutable COLLATERAL_TOKEN;

    uint64 public immutable DEFAULT_COLLATERAL_MULTIPLIER;
    uint32 constant DISPUTE_PERIOD = FOUR_CONFIRMATIONS;
    uint32 constant MIN_TIME_FOR_INCLUSION = TWO_CONFIRMATIONS;
    uint32 constant CAN_VALIDATE_OUTPUTS_FOR = 1 days;

    /**
     * @dev Solvers have an additional LEAD_TIME to fill orders.
     */
    uint32 constant LEAD_TIME = 7 minutes;

    uint32 constant ONE_CONFIRMATION = 69 minutes;
    uint32 constant TWO_CONFIRMATIONS = 93 minutes;
    uint32 constant THREE_CONFIRMATIONS = 112 minutes;
    uint32 constant FOUR_CONFIRMATIONS = 131 minutes;
    uint32 constant FIVE_CONFIRMATIONS = 148 minutes;
    uint32 constant SIX_CONFIRMATIONS = 165 minutes;
    uint32 constant SEVEN_CONFIRMATIONS = 181 minutes;
    uint32 constant TIME_PER_ADDITIONAL_CONFIRMATION = 15 minutes;

    /**
     * @notice Returns the number of seconds required to reach confirmation with 99.9%
     * certainty.
     * How long does it take for us to get 99,9% confidence that a transaction will
     * be confirmable. Examine n identically distributed exponentially random variables
     * with rate 1/10. The sum of the random variables are distributed gamma(n, 1/10).
     * The 99,9% quantile of the distribution can be found in R as qgamma(0.999, n, 1/10)
     * 1 confirmations: 69 minutes.
     * 3 confirmations: 112 minutes.
     * 5 confirmations: 148 minutes.
     * 7 confirmations: 181 minutes.
     * You may wonder why the delta decreases as we increase confirmations?
     * That is the law of large numbers in action.
     * @dev Cannot handle confirmations == 0. Silently returns 181 minutes as a failure.
     */
    function _getProofPeriod(
        uint256 confirmations
    ) internal pure returns (uint256) {
        unchecked {
            uint256 gammaDistribution = confirmations <= 3
                ? (confirmations == 1 ? ONE_CONFIRMATION : (confirmations == 2 ? TWO_CONFIRMATIONS : THREE_CONFIRMATIONS))
                : (
                    confirmations < 8
                        ? (
                            confirmations == 4
                                ? FOUR_CONFIRMATIONS
                                : (
                                    confirmations == 5
                                        ? FIVE_CONFIRMATIONS
                                        : (confirmations == 6 ? SIX_CONFIRMATIONS : SEVEN_CONFIRMATIONS)
                                )
                        )
                        : 181 minutes + (confirmations - 7) * TIME_PER_ADDITIONAL_CONFIRMATION
                );
            return gammaDistribution + LEAD_TIME;
        }
    }

    function _readMultiplier(
        bytes calldata fulfillmentContext
    ) internal view returns (uint256 multiplier) {
        uint256 fulfillmentLength = fulfillmentContext.length;
        if (fulfillmentLength == 0) return DEFAULT_COLLATERAL_MULTIPLIER;
        bytes1 orderType = bytes1(fulfillmentContext);
        if (orderType == 0xB0 && fulfillmentLength == 33) {
            // multiplier = abi.decode(fulfillmentContext, uint64);
            assembly ("memory-safe") {
                multiplier := calldataload(add(fulfillmentContext.offset, 0x01))
            }
        }
        return multiplier != 0 ? multiplier : DEFAULT_COLLATERAL_MULTIPLIER;
    }

    constructor(
        address _lightClient,
        address disputedOrderFeeDestination,
        address collateralToken,
        uint64 collateralMultiplier
    ) payable {
        LIGHT_CLIENT = _lightClient;
        DISPUTED_ORDER_FEE_DESTINATION = disputedOrderFeeDestination;
        COLLATERAL_TOKEN = collateralToken;
        DEFAULT_COLLATERAL_MULTIPLIER = collateralMultiplier;
    }

    function _outputIdentifier(
        MandateOutput calldata output
    ) internal pure returns (bytes32) {
        return keccak256(MandateOutputEncodingLib.encodeMandateOutput(output));
    }

    function outputIdentifier(
        MandateOutput calldata output
    ) external pure returns (bytes32) {
        return _outputIdentifier(output);
    }

    //--- Light Client Helpers ---//
    // Helper functions to aid integration of other light clients.
    // These functions are the only external calls needed to prove Bitcoin transactions.
    // If you are adding support for another light client, inherit this contract and
    // overwrite these functions.

    /**
     * @notice Helper function to get the latest block height.
     * Is used to validate confirmations
     * @dev Is intended to be overwritten if another SPV client than Prism is used.
     */
    function _getLatestBlockHeight() internal view virtual returns (uint256 currentHeight) {
        return currentHeight = IBtcPrism(LIGHT_CLIENT).getLatestBlockHeight();
    }

    /**
     * @notice Helper function to get the blockhash at a specific block number.
     * Is used to check if block headers are valid.
     * @dev Is intended to be overwritten if another SPV client than Prism is used.
     */
    function _getBlockHash(
        uint256 blockNum
    ) internal view virtual returns (bytes32 blockHash) {
        return blockHash = IBtcPrism(LIGHT_CLIENT).getBlockHash(blockNum);
    }

    //--- Bitcoin Helpers ---//

    /**
     * @notice Slices the timestamp from a Bitcoin block header.
     * @dev Before calling this function, make sure the header is 80 bytes.
     */
    function _getTimestampOfBlock(
        bytes calldata blockHeader
    ) internal pure returns (uint256 timestamp) {
        return timestamp = Endian.reverse32(uint32(bytes4(blockHeader[68:68 + 4])));
    }

    function _getTimestampOfPreviousBlock(
        bytes calldata previousBlockHeader,
        BtcTxProof calldata inclusionProof
    ) internal pure returns (uint256 timestamp) {
        // Check that previousBlockHeader is 80 bytes. While technically not needed
        // since the hash of previousBlockHeader.length > 80 won't match the correct hash
        // this is a sanity check that if nothing else ensures that objectively bad
        // headers are never provided.
        require(previousBlockHeader.length == 80);

        // Get block hash of the previousBlockHeader.
        bytes32 proposedPreviousBlockHash = BtcProof.getBlockHash(previousBlockHeader);
        // Load the actual previous block hash from the header of the block we just proved.
        bytes32 actualPreviousBlockHash = bytes32(Endian.reverse256(uint256(bytes32(inclusionProof.blockHeader[4:36]))));
        if (actualPreviousBlockHash != proposedPreviousBlockHash) {
            revert BlockhashMismatch(actualPreviousBlockHash, proposedPreviousBlockHash);
        }

        // This is now provably the previous block. As a result, we return the timestamp of the previous block.
        return _getTimestampOfBlock(previousBlockHeader);
    }

    /**
     * @notice Returns the associated Bitcoin script given an order token (address type) & destination (script hash).
     * @param token Bitcoin signifier (is checked) and the address version.
     * @param scriptHash Bitcoin address identifier hash.
     * Depending on address version is: Public key hash, script hash, or witness hash.
     * @return script Bitcoin output script matching the given parameters.
     */
    function _bitcoinScript(bytes32 token, bytes32 scriptHash) internal pure returns (bytes memory script) {
        // Check for the Bitcoin signifier:
        if (bytes30(token) != BITCOIN_AS_TOKEN) revert BadTokenFormat();

        // Load address version.
        AddressType bitcoinAddressType = AddressType(uint8(uint256(token)));

        return BtcScript.getBitcoinScript(bitcoinAddressType, scriptHash);
    }

    /**
     * @notice Loads the number of confirmations from the second last byte of the token.
     * @dev "0" confirmations are converted into 1.
     * How long does it take for us to get 99,9% confidence that a transaction will
     * be confirmable. Examine n identically distributed exponentially random variables
     * with rate 1/10. The sum of the random variables are distributed gamma(n, 1/10).
     * The 99,9% quantile of the distribution can be found in R as qgamma(0.999, n, 1/10)
     * 1 confirmations: 69 minutes.
     * 3 confirmations: 112 minutes.
     * 5 confirmations: 148 minutes.
     * 7 confirmations: 181 minutes.
     * You may wonder why the delta decreases as we increase confirmations?
     * That is the law of large numbers in action.
     */
    function _getNumConfirmations(
        bytes32 token
    ) internal pure returns (uint8 numConfirmations) {
        assembly ("memory-safe") {
            // numConfirmations = token << 240 [nc, utxo, 0...]
            // numConfirmations = numConfirmations >> 248 [...0, nc]
            numConfirmations := shr(248, shl(240, token))

            // numConfirmations = numConfirmations == 0 ? 1 : numConfirmations
            numConfirmations := add(eq(numConfirmations, 0), numConfirmations)
        }
    }

    // --- Data Validation Function --- //

    /**
     * @notice The Bitcoin Oracle should also work as an filler if it sits locally on a chain.
     * We don't want to store 2 attests of proofs (filler and oracle uses different schemes) so we instead store the
     * payload attestation. That allows settlers to easily check if outputs has been filled but also if payloads
     * have been verified (incase the settler is on another chain than the light client).
     */
    function _isPayloadValid(
        bytes32 payloadHash
    ) internal view returns (bool) {
        return _attestations[block.chainid][bytes32(uint256(uint160(address(this))))][bytes32(
            uint256(uint160(address(this)))
        )][payloadHash];
    }

    /**
     * @dev Allows oracles to verify we have confirmed payloads.
     */
    function arePayloadsValid(
        bytes32[] calldata payloadHashes
    ) external view returns (bool) {
        uint256 numPayloads = payloadHashes.length;
        bool accumulator = true;
        for (uint256 i; i < numPayloads; ++i) {
            accumulator = accumulator && _isPayloadValid(payloadHashes[i]);
        }
        return accumulator;
    }

    // --- Validation --- //

    /**
     * @notice Verifies the existence of a Bitcoin transaction and returns the number of satoshis associated
     * with output txOutIx of the transaction.
     * @dev Does not return _when_ it happened except that it happened on blockNum.
     * @param minConfirmations Number of confirmations before transaction is considered valid.
     * @param blockNum Block number of the transaction.
     * @param inclusionProof Proof for transaction & transaction data.
     * @param txOutIx Index of the outputs to be examined against for output script and sats.
     * @param outputScript The expected output script. Compared to the actual, reverts if different.
     * @param embeddedData If provided (!= 0x), the next output (txOutIx+1) is checked to contain
     * the spend script: OP_RETURN | PUSH_(embeddedData.length) | embeddedData
     * See the Prism library BtcScript for more information.
     * @return sats Value of txOutIx TXO of the transaction.
     */
    function _validateUnderlyingPayment(
        uint256 minConfirmations,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx,
        bytes memory outputScript,
        bytes calldata embeddedData
    ) internal view virtual returns (uint256 sats) {
        // Isolate height check. This slightly decreases gas cost.
        {
            uint256 currentHeight = _getLatestBlockHeight();

            if (currentHeight < blockNum) revert NoBlock(currentHeight, blockNum);

            unchecked {
                // Unchecked: currentHeight >= blockNum => currentHeight - blockNum >= 0
                // Bitcoin block heights are smaller than timestamp :)
                if (currentHeight + 1 - blockNum < minConfirmations) {
                    revert TooFewConfirmations(currentHeight + 1 - blockNum, minConfirmations);
                }
            }
        }

        // Load the expected hash for blockNum. This is the "security" call of the light client.
        // If block hash matches the hash of inclusionProof.blockHeader then we know it is a
        // valid block.
        bytes32 blockHash = _getBlockHash(blockNum);

        bytes memory txOutScript;
        bytes memory txOutData;
        if (embeddedData.length > 0) {
            // Important, this function validate that blockHash = hash(inclusionProof.blockHeader);
            // This function fails if txOutIx + 1 does not exist.
            (sats, txOutScript, txOutData) = BtcProof.validateTxData(blockHash, inclusionProof, txOutIx);

            if (!BtcProof.compareScripts(outputScript, txOutScript)) revert ScriptMismatch(outputScript, txOutScript);

            // Get the expected op_return script: OP_RETURN | PUSH_(embeddedData.length) | embeddedData
            bytes memory opReturnData = BtcScript.embedOpReturn(embeddedData);
            if (!BtcProof.compareScripts(opReturnData, txOutData)) revert ScriptMismatch(opReturnData, txOutData);
            return sats;
        }

        // Important, this function validate that blockHash = hash(inclusionProof.blockHeader);
        (sats, txOutScript) = BtcProof.validateTx(blockHash, inclusionProof, txOutIx);

        if (!BtcProof.compareScripts(outputScript, txOutScript)) revert ScriptMismatch(outputScript, txOutScript);
    }

    /**
     * @dev This function does not validate that the output is for this contract.
     * Instead it assumes that the caller correctly identified that this contract is the proper
     * contract to call. This is fine, since we never read the chainId nor remoteOracle
     * when setting the payload as proven.
     */
    function _verify(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx,
        uint256 timestamp
    ) internal {
        // Validate that the transaction happened recently:
        if (timestamp + CAN_VALIDATE_OUTPUTS_FOR < block.timestamp) revert TooLate();

        bytes32 token = output.token;
        bytes memory outputScript = _bitcoinScript(token, output.recipient);
        uint256 numConfirmations = _getNumConfirmations(token);
        uint256 sats = _validateUnderlyingPayment(
            numConfirmations, blockNum, inclusionProof, txOutIx, outputScript, output.remoteCall
        );

        // Check that the amount matches exactly. This is important since if the assertion
        // was looser it will be much harder to protect against "double spends".
        if (sats != output.amount) revert BadAmount();

        // Get the solver of the order.
        bytes32 solver = _resolveClaimed(uint32(timestamp), orderId, output);

        // Store attestation.
        bytes32 outputHash =
            keccak256(MandateOutputEncodingLib.encodeFillDescription(solver, orderId, uint32(timestamp), output));
        _attestations[block.chainid][bytes32(uint256(uint160(address(this))))][bytes32(uint256(uint160(address(this))))][outputHash]
        = true;

        // We need to emit this event to make the output recognisably observably filled off-chain.
        emit OutputFilled(orderId, solver, uint32(timestamp), output);
        emit OutputVerified(inclusionProof.txId);
    }

    /**
     * @notice Validate an output is correct.
     * @dev Specifically, this function uses the other validation functions and adds some
     * Bitcoin context surrounding it.
     * @param output Output to prove.
     * @param blockNum Bitcoin block number of the transaction that the output is included in.
     * @param inclusionProof Proof of inclusion. fillDeadline is validated against Bitcoin block timestamp.
     * @param txOutIx Index of the output in the transaction being proved.
     */
    function _verifyAttachTimestamp(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx
    ) internal {
        // Check the timestamp. This is done before inclusionProof is checked for validity
        // so it can be manipulated but if it has been manipulated the later check (_validateUnderlyingPayment)
        // won't pass. _validateUnderlyingPayment checks if inclusionProof.blockHeader == 80.
        uint256 timestamp = _getTimestampOfBlock(inclusionProof.blockHeader);

        _verify(orderId, output, blockNum, inclusionProof, txOutIx, timestamp);
    }

    /**
     * @notice Function overload of _verify but allows specifying an older block.
     * @dev This function technically extends the verification of outputs 1 block (~10 minutes)
     * into the past beyond what _validateTimestamp would ordinary allow.
     * The purpose is to protect against slow block mining. Even if it took days to mine 1 block for a transaction,
     * it would still be possible to include the proof with a valid time. (assuming the oracle period isn't over yet).
     */
    function _verifyAttachTimestamp(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx,
        bytes calldata previousBlockHeader
    ) internal {
        // Get the timestamp of block before the one we that the transaction was included in.
        uint256 timestamp = _getTimestampOfPreviousBlock(previousBlockHeader, inclusionProof);

        _verify(orderId, output, blockNum, inclusionProof, txOutIx, timestamp);
    }

    /**
     * @notice Validate an output is correct and included in a block with appropriate confiration.
     * @param orderId Identifier for the order. Is used to check that the order has been correctly proviced
     * and to find the associated claim.
     * @param output TODO:
     * @param blockNum Bitcoin block number of block that included the transaction.
     * @param inclusionProof Proof of inclusion.
     * @param txOutIx Index of the output in the transaction being proved.
     */
    function verify(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx
    ) external {
        _verifyAttachTimestamp(orderId, output, blockNum, inclusionProof, txOutIx);
    }

    /**
     * @notice Function overload of verify but allows specifying an older block.
     * @dev This function technically extends the verification of outputs 1 block (~10 minutes)
     * into the past beyond what _validateTimestamp would ordinary allow.
     * The purpose is to protect against slow block mining. Even if it took days to get confirmation on a transaction,
     * it would still be possible to include the proof with a valid time. (assuming the oracle period isn't over yet).
     */
    function verify(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx,
        bytes calldata previousBlockHeader
    ) external {
        _verifyAttachTimestamp(orderId, output, blockNum, inclusionProof, txOutIx, previousBlockHeader);
    }

    // --- Optimistic Resolution AND Order-Preclaiming --- //
    // For Bitcoin, it is required that outputs are claimed before they are delivered.
    // This is because it is impossible to block duplicate deliveries on Bitcoin in the same way
    // that is possible with EVM. (Actually, not true. It is just much more expensive – any-spend anchors).

    /**
     * @notice Returns the solver associated with the claim.
     * @dev Allows reentry calls. Does not honor the check effect pattern globally.
     */
    function _resolveClaimed(
        uint32 fillTimestamp,
        bytes32 orderId,
        MandateOutput calldata output
    ) internal returns (bytes32 solver) {
        bytes32 outputId = _outputIdentifier(output);
        ClaimedOrder storage claimedOrder = _claimedOrder[orderId][outputId];
        solver = claimedOrder.solver;
        if (solver == bytes32(0)) revert NotClaimed();

        // Check if there are outstanding collateral associated with the
        // registered claim.
        address sponsor = claimedOrder.sponsor;
        uint96 multiplier = claimedOrder.multiplier;
        uint32 disputeTimestamp = claimedOrder.disputeTimestamp;
        address disputer = claimedOrder.disputer;

        // Check if the fill was before the disputeTimestamp.
        // - fillTimestamp >= claimTimestamp is not checked and it is assumed the
        // 1 day validation window is sufficient to check that the transaction was
        // made to fill this output.
        // - recall that the dispute timestamp has a sufficient
        if (sponsor != address(0) && (disputer == address(0) || fillTimestamp <= disputeTimestamp)) {
            bool disputed = disputer != address(0);
            // If the order has been disputed, we need to also collect the disputers collateral for the solver.

            // Delete storage so no re-entry.
            delete claimedOrder.solver;
            delete claimedOrder.multiplier;
            delete claimedOrder.claimTimestamp;
            delete claimedOrder.sponsor;
            delete claimedOrder.disputer;
            delete claimedOrder.disputeTimestamp;

            uint256 collateralAmount = output.amount * multiplier;
            uint256 disputeCost = collateralAmount - collateralAmount / DISPUTED_ORDER_FEE_FRACTION;
            collateralAmount =
                disputed ? collateralAmount * (CHALLENGER_COLLATERAL_FACTOR + 1) - disputeCost : collateralAmount;

            SafeTransferLib.safeTransfer(COLLATERAL_TOKEN, sponsor, collateralAmount);
            if (disputed && 0 < disputeCost) {
                SafeTransferLib.safeTransfer(COLLATERAL_TOKEN, DISPUTED_ORDER_FEE_DESTINATION, disputeCost);
            }
        }
    }

    /**
     * @notice Claim an order.
     * @dev Only works when the order identifier is exactly as on EVM.
     * @param solver Identifier to set as the solver.
     * @param output The output to verify
     */
    function claim(bytes32 solver, bytes32 orderId, MandateOutput calldata output) external {
        if (solver == bytes32(0)) revert ZeroValue();
        if (orderId == bytes32(0)) revert ZeroValue();

        bytes32 outputId = _outputIdentifier(output);
        // Check that this order hasn't been claimed before.
        ClaimedOrder storage claimedOrder = _claimedOrder[orderId][outputId];
        if (claimedOrder.solver != bytes32(0)) revert AlreadyClaimed(claimedOrder.solver);
        uint256 multiplier = _readMultiplier(output.fulfillmentContext);

        claimedOrder.solver = solver;
        claimedOrder.claimTimestamp = uint32(block.timestamp);
        claimedOrder.sponsor = msg.sender;
        claimedOrder.multiplier = uint64(multiplier);
        // The above lines acts as a local re-entry guard. External calls are now allowed.

        // Collect collateral from claimant.
        uint256 collateralAmount = output.amount * multiplier;
        SafeTransferLib.safeTransferFrom(COLLATERAL_TOKEN, msg.sender, address(this), collateralAmount);

        emit OutputClaimed(orderId, outputId);
    }

    /**
     * @notice Dispute an order.
     * @param orderId Order Identifier
     * @param output Output description of the order to dispute.
     */
    function dispute(bytes32 orderId, MandateOutput calldata output) external {
        bytes32 outputId = _outputIdentifier(output);

        // Check that this order has been claimed but not disputed..
        ClaimedOrder storage claimedOrder = _claimedOrder[orderId][outputId];
        if (claimedOrder.claimTimestamp + DISPUTE_PERIOD < block.timestamp) revert TooLate();
        if (claimedOrder.solver == bytes32(0)) revert NotClaimed();

        if (claimedOrder.disputer != address(0)) revert AlreadyDisputed(claimedOrder.disputer);
        claimedOrder.disputer = msg.sender;

        // Allow for a minimum amount of time to get the transaction included. The
        uint32 currentTimestamp = uint32(block.timestamp);
        uint32 inclusionTimestamp = uint32(claimedOrder.claimTimestamp + MIN_TIME_FOR_INCLUSION);
        claimedOrder.disputeTimestamp = currentTimestamp < inclusionTimestamp ? inclusionTimestamp : currentTimestamp;

        uint256 collateralAmount = output.amount * claimedOrder.multiplier;
        collateralAmount = collateralAmount * CHALLENGER_COLLATERAL_FACTOR;

        // Collect collateral from disputer.
        SafeTransferLib.safeTransferFrom(COLLATERAL_TOKEN, msg.sender, address(this), collateralAmount);

        emit OutputDisputed(orderId, _outputIdentifier(output));
    }

    /**
     * @notice Optimistically verify an order if the order has not been disputed.
     * @dev Sets all outputs belonging to this contract as validated on storage
     */
    function optimisticallyVerify(bytes32 orderId, MandateOutput calldata output) external {
        bytes32 outputId = _outputIdentifier(output);

        ClaimedOrder storage claimedOrder = _claimedOrder[orderId][outputId];
        if (claimedOrder.solver == bytes32(0)) revert NotClaimed();
        if (claimedOrder.claimTimestamp + DISPUTE_PERIOD >= block.timestamp) revert TooEarly();
        bool disputed = claimedOrder.disputer != address(0);
        if (disputed) revert Disputed();

        bytes32 solver = claimedOrder.solver;
        bytes32 outputHash =
            keccak256(MandateOutputEncodingLib.encodeFillDescription(solver, orderId, uint32(block.timestamp), output));
        _attestations[block.chainid][bytes32(uint256(uint160(address(this))))][bytes32(uint256(uint160(address(this))))][outputHash]
        = true;
        emit OutputFilled(orderId, solver, uint32(block.timestamp), output);

        address sponsor = claimedOrder.sponsor;
        uint256 multiplier = claimedOrder.multiplier;

        // Delete the claim details.
        delete claimedOrder.solver;
        delete claimedOrder.multiplier;
        delete claimedOrder.claimTimestamp;
        delete claimedOrder.sponsor;
        delete claimedOrder.disputer;
        delete claimedOrder.disputeTimestamp;

        uint256 collateralAmount = output.amount * multiplier;
        SafeTransferLib.safeTransfer(COLLATERAL_TOKEN, sponsor, collateralAmount);

        emit OutputOptimisticallyVerified(orderId, _outputIdentifier(output));
    }

    /**
     * @notice Finalise a dispute if the order hasn't been proven.
     */
    function finaliseDispute(bytes32 orderId, MandateOutput calldata output) external {
        bytes32 outputId = _outputIdentifier(output);

        ClaimedOrder storage claimedOrder = _claimedOrder[orderId][outputId];
        address disputer = claimedOrder.disputer;
        uint256 multiplier = claimedOrder.multiplier;
        if (disputer == address(0)) revert NotDisputed();

        uint256 numConfirmations = _getNumConfirmations(output.token);
        uint256 proofPeriod = _getProofPeriod(numConfirmations);
        uint256 disputeTimestamp = claimedOrder.disputeTimestamp;

        if (disputeTimestamp + proofPeriod >= block.timestamp) revert TooEarly();

        // Delete the dispute details.
        delete claimedOrder.solver;
        delete claimedOrder.multiplier;
        delete claimedOrder.claimTimestamp;
        delete claimedOrder.sponsor;
        delete claimedOrder.disputer;
        delete claimedOrder.disputeTimestamp;

        uint256 collateralAmount = output.amount * multiplier;
        uint256 disputeCost = collateralAmount - collateralAmount / DISPUTED_ORDER_FEE_FRACTION;
        collateralAmount = collateralAmount * (CHALLENGER_COLLATERAL_FACTOR + 1);
        SafeTransferLib.safeTransfer(COLLATERAL_TOKEN, disputer, collateralAmount - disputeCost);
        if (0 < disputeCost) {
            SafeTransferLib.safeTransfer(COLLATERAL_TOKEN, DISPUTED_ORDER_FEE_DESTINATION, disputeCost);
        }

        emit OutputDisputeFinalised(orderId, _outputIdentifier(output));
    }
}
