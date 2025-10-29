// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Endian } from "./external/Endian.sol";
import { IBtcPrism } from "./external/interfaces/IBtcPrism.sol";
import { NoBlock, TooFewConfirmations } from "./external/interfaces/IBtcTxVerifier.sol";
import { BtcProof, BtcTxProof, ScriptMismatch } from "./external/library/BtcProof.sol";
import { AddressType, BitcoinAddress, BtcScript } from "./external/library/BtcScript.sol";

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { AssemblyLib } from "../../../libs/AssemblyLib.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MandateOutput, MandateOutputEncodingLib } from "../../../libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../../../libs/OutputVerificationLib.sol";

import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";

/**
 * @dev Bitcoin oracle can operate in 2 modes:
 * 1. Directly as an Output Settlement.
 * 2. Indirectly through a bridge oracle.
 * While the former is a simpler deployment, it requires a local light client. Thus it may be favorable to only maintain
 * 1 lightclient and send generated proofs to the input chain.
 *
 * Because of the above operation, the chain of this oracle needs to be encoded into MandateOutput: output.chainId. To
 * indicate the destination is Bitcoin the token is set to: BITCOIN_AS_TOKEN
 * Bitcoin addresses can encoded in at most 33 bytes: 32 bytes of script- or witnesshash or 20 bytes of pubkeyhash +
 * 1 byte of address type identification. Since the recipient is only 32 bytes the remaining byte (address type) will be
 * encoded in the token as the right most byte. Another byte of the token is used to set confirmations as a uint8.
 * The result is the token is: 30B: BITCOIN_AS_TOKEN | 1B: Confirmations | 1B: Address type.
 *
 * 0xB17C012
 */
contract BitcoinOracle is BaseInputOracle {
    using LibAddress for address;

    error AlreadyClaimed(bytes32 claimer);
    error AlreadyDisputed(address disputer);
    error BadAmount();
    error BadTokenFormat();
    error BlockhashMismatch(bytes32 actual, bytes32 proposed);
    error Disputed();
    error NotClaimed();
    error NotDisputed();
    error TooEarly();
    error TooLate();
    error ZeroValue();

    event OutputFilled(
        bytes32 indexed orderId, bytes32 solver, uint32 timestamp, MandateOutput output, uint256 finalAmount
    );
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
        address claimant;
        address disputer;
        /// @notice For a claim to be paid to the claimant, the input has to be included before this timestamp.
        /// For disputers, note that it is possible to set the inclusion timestamp to 1 block prior.
        /// @dev Is the maximum of (block.timestamp and claimTimestamp + MIN_TIME_FOR_INCLUSION)
        uint32 disputeTimestamp;
    }

    mapping(bytes32 orderId => mapping(bytes32 outputId => ClaimedOrder)) public _claimedOrder;

    /// @notice The Bitcoin Identifier (0xBC) is set in the 20'th byte (from right). This ensures
    /// implementations that are only reading the last 20 bytes, still notice this is a Bitcoin address.
    /// This also standardizes support for other light clients coins (Lightcoin 0x1C?)
    bytes30 constant BITCOIN_AS_TOKEN = 0x000000000000000000000000BC0000000000000000000000000000000000;

    address public immutable LIGHT_CLIENT;

    /// @notice The purpose of the dispute fee is to make sure that 1 person can't claim and dispute the transaction at
    /// no risk.
    address public immutable DISPUTED_ORDER_FEE_DESTINATION;
    uint256 public constant DISPUTED_ORDER_FEE_FRACTION = 3;

    /// @notice Require that the challenger provides X times the collateral of the claimant.
    uint256 public constant CHALLENGER_COLLATERAL_FACTOR = 2;
    IERC20 public immutable COLLATERAL_TOKEN;
    uint64 public immutable DEFAULT_COLLATERAL_MULTIPLIER;
    uint32 constant DISPUTE_PERIOD = FOUR_CONFIRMATIONS;
    uint32 constant MIN_TIME_FOR_INCLUSION = TWO_CONFIRMATIONS;
    uint32 constant CAN_VALIDATE_OUTPUTS_FOR = 1 days;

    /// @dev Solvers have an additional LEAD_TIME to fill orders.
    uint32 constant LEAD_TIME = 7 minutes;

    /// @notice Bitcoin blocks arrive exponentially distributed. The arrival times of n block will be n identically
    /// distributed exponentially random variables with rate 1/10. The sum of the these random variables are distributed
    /// gamma(n, 1/10). The 99,9% quantile of the distribution can be found in R as qgamma(0.999, n, 1/10)
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
     * @dev confirmations == 0 returns 119 minutes.
     * @param confirmations Current block height - inclusion block height + 1.
     * @return Expected time to reach the confirmation with 99,9% certainty.
     */
    function _getProofPeriod(
        uint256 confirmations
    ) internal pure returns (uint256) {
        unchecked {
            uint256 gammaDistribution = confirmations <= 3
                ? (confirmations == 1
                        ? ONE_CONFIRMATION
                        : (confirmations == 2 ? TWO_CONFIRMATIONS : THREE_CONFIRMATIONS))
                : (confirmations < 8
                        ? (confirmations == 4
                                ? FOUR_CONFIRMATIONS
                                : (confirmations == 5
                                        ? FIVE_CONFIRMATIONS
                                        : (confirmations == 6 ? SIX_CONFIRMATIONS : SEVEN_CONFIRMATIONS)))
                        : 181 minutes + (confirmations - 7) * TIME_PER_ADDITIONAL_CONFIRMATION);
            return gammaDistribution + LEAD_TIME;
        }
    }

    constructor(
        address _lightClient,
        address disputedOrderFeeDestination,
        address collateralToken,
        uint64 collateralMultiplier
    ) payable {
        LIGHT_CLIENT = _lightClient;
        DISPUTED_ORDER_FEE_DESTINATION = disputedOrderFeeDestination;
        COLLATERAL_TOKEN = IERC20(collateralToken);
        DEFAULT_COLLATERAL_MULTIPLIER = collateralMultiplier;
    }

    //--- Light Client Helpers ---//
    // Helper functions to aid integration of other light clients.
    // These functions are the only external calls needed to prove Bitcoin transactions.
    // If you are adding support for another light client, inherit this contract and
    // overwrite these functions.

    /**
     * @notice Gets the latest block height. Used to validate confirmations
     * @dev Is intended to be overwritten if another SPV client than Prism is used.
     * @return currentHeight Block height of the Bitcoin chain head.
     */
    function _getLatestBlockHeight() internal view virtual returns (uint256 currentHeight) {
        return currentHeight = IBtcPrism(LIGHT_CLIENT).getLatestBlockHeight();
    }

    /**
     * @notice Gets the block hash at a recent block number. Used to check if block headers are valid.
     * @dev Is intended to be overwritten if another SPV client than Prism is used.
     * @param blockNum Bitcoin block height.
     * @param blockHash Hash of Bitcoin block.
     */
    function _getBlockHash(
        uint256 blockNum
    ) internal view virtual returns (bytes32 blockHash) {
        return blockHash = IBtcPrism(LIGHT_CLIENT).getBlockHash(blockNum);
    }

    // --- Output Identifiers --- //

    function _outputIdentifier(
        MandateOutput calldata output
    ) internal pure returns (bytes32) {
        return MandateOutputEncodingLib.getMandateOutputHash(output);
    }

    function outputIdentifier(
        MandateOutput calldata output
    ) external pure returns (bytes32) {
        return _outputIdentifier(output);
    }

    /**
     * @notice Reads the multiplier from the order context.
     * The expected encoding of the context is:
     * 0xB0: Bitcoin multiplier : B1:orderType | B32:multiplier
     * @dev Returns DEFAULT_COLLATERAL_MULTIPLIER if context can not be decoded.
     * @param context Output context to be decoded.
     * @return multiplier Collateral multiplier
     */
    function _readMultiplier(
        bytes calldata context
    ) internal view returns (uint256 multiplier) {
        uint256 fulfillmentLength = context.length;
        if (fulfillmentLength == 0) return DEFAULT_COLLATERAL_MULTIPLIER;
        if (bytes1(context) == 0xB0 && fulfillmentLength == 33) {
            // (, multiplier) = abi.decode(context, (bytes1, uint64));
            assembly ("memory-safe") {
                multiplier := calldataload(add(context.offset, 0x01))
            }
        }
        return multiplier != 0 ? multiplier : DEFAULT_COLLATERAL_MULTIPLIER;
    }

    //--- Bitcoin Helpers ---//

    /**
     * @notice Slices the timestamp from a Bitcoin block header.
     * @dev Before calling this function, make sure the header is 80 bytes.
     * @param blockHeader 80 bytes Bitcoin block header.
     * @return timestamp Timestamp contained within the block header. Notice that Bitcoin block headers has fairly loose
     * timestamp rules.
     */
    function _getTimestampOfBlock(
        bytes calldata blockHeader
    ) internal pure returns (uint32 timestamp) {
        return timestamp = Endian.reverse32(uint32(bytes4(blockHeader[68:68 + 4])));
    }

    /**
     * @notice Slices the timestamp from a previous Bitcoin block header and verifies the previous block header hash is
     * contained in the header of the current one.
     * @dev This function does not verify the length of the block headers. It instead relies on previousBlockHeader not
     * hashing to the proper hash if not 80 bytes.
     * @param previousBlockHeader 80 bytes Bitcoin block header.
     * @param currentBlockHeader 80 bytes Bitcoin block header containing the hash of previousBlockHeader.
     * @return timestamp Timestamp contained within the previous block header. Notice that Bitcoin block headers has
     * fairly loose timestamp rules.
     */
    function _getTimestampOfPreviousBlock(
        bytes calldata previousBlockHeader,
        bytes calldata currentBlockHeader
    ) internal pure returns (uint32 timestamp) {
        bytes32 proposedPreviousBlockHash = BtcProof.getBlockHash(previousBlockHeader);
        bytes32 actualPreviousBlockHash = bytes32(Endian.reverse256(uint256(bytes32(currentBlockHeader[4:36]))));
        if (actualPreviousBlockHash != proposedPreviousBlockHash) {
            revert BlockhashMismatch(actualPreviousBlockHash, proposedPreviousBlockHash);
        }
        return _getTimestampOfBlock(previousBlockHeader);
    }

    /**
     * @notice Returns the associated Bitcoin script given an order token (address type) & destination (script hash).
     * @param token Bitcoin signifier and the address version.
     * @param scriptHash Depending on address version is: Public key hash, script hash, or witness hash.
     * @return script Bitcoin output script.
     */
    function _bitcoinScript(
        bytes32 token,
        bytes32 scriptHash
    ) internal pure returns (bytes memory script) {
        if (bytes30(token) != BITCOIN_AS_TOKEN) revert BadTokenFormat();
        AddressType bitcoinAddressType = AddressType(uint8(uint256(token)));
        return BtcScript.getBitcoinScript(bitcoinAddressType, scriptHash);
    }

    /**
     * @notice Loads the number of confirmations from the second last byte of the token.
     * @param token Confirmation encoded in bytes32 as the second right most byte.
     * @return numConfirmations Number of confirmations, 1 if 0 was encoded.
     */
    function _getNumConfirmations(
        bytes32 token
    ) internal pure returns (uint8 numConfirmations) {
        assembly ("memory-safe") {
            // numConfirmations = token [0..., BC, 0..., nc, utxo]
            // numConfirmations = token << 240 [nc, utxo, 0...]
            // numConfirmations = numConfirmations >> 248 [...0, nc]
            numConfirmations := shr(248, shl(240, token))

            // numConfirmations = numConfirmations == 0 ? 1 : numConfirmations
            numConfirmations := add(eq(numConfirmations, 0), numConfirmations)
        }
    }

    // --- Data Validation Function --- //

    /**
     * @notice The Bitcoin Oracle should also work as an output settler if it sits locally on a chain.
     * Instead of storing 2 attestations of proofs (output settler and oracle uses different schemes) the payload
     * attestation is stored instead. That allows settlers to check if outputs has been filled but also if payloads are
     * valid (if accessed through an oracle).
     * @param payload Bytes encoded payload to verify.
     * @return bool Whether the payload has been verified.
     */
    function _isPayloadValid(
        bytes calldata payload
    ) internal view returns (bool) {
        bytes32 payloadHash = keccak256(payload);
        return _attestations[block.chainid][(msg.sender).toIdentifier()][address(this).toIdentifier()][payloadHash];
    }

    /**
     * @dev Allows oracles to verify we have confirmed payloads.
     */
    function hasAttested(
        bytes[] calldata payloads
    ) external view returns (bool accumulator) {
        accumulator = true;
        uint256 numPayloads = payloads.length;
        for (uint256 i; i < numPayloads; ++i) {
            accumulator = AssemblyLib.and(accumulator, _isPayloadValid(payloads[i]));
        }
    }

    // --- Validation --- //

    /**
     * @notice Verifies the existence of a Bitcoin transaction and returns the number of satoshis associated with an
     * output of the transaction.
     * @param minConfirmations Number of confirmations before transaction is considered valid.
     * @param blockNum Bitcoin block number of block that included the transaction that fills the output.
     * @param inclusionProof Proof for transaction & transaction data.
     * @param txOutIndex Output index of the transaction to be examined against for output script and sats.
     * @param outputScript The expected output script.
     * @param embeddedData If provided (!= 0x), the output after txOutIndex is checked to contain the spend script:
     * OP_RETURN | PUSH_(embeddedData.length) | embeddedData. See the Prism library BtcScript for more information.
     * @return sats Value of txOutIx TXO of the transaction.
     */
    function _validateUnderlyingPayment(
        uint256 minConfirmations,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIndex,
        bytes memory outputScript,
        bytes calldata embeddedData
    ) internal view virtual returns (uint256 sats) {
        {
            uint256 currentHeight = _getLatestBlockHeight();

            if (currentHeight < blockNum) revert NoBlock(currentHeight, blockNum);

            unchecked {
                // Unchecked: currentHeight >= blockNum => currentHeight - blockNum >= 0
                // Bitcoin block heights are smaller than timestamps :)
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
        if (embeddedData.length > 0) {
            // This function validates that blockHash == hash(inclusionProof.blockHeader);
            // Fails if txOutIx + 1 does not exist.
            bytes memory nextOutputScript;
            (sats, txOutScript, nextOutputScript) = BtcProof.validateTxData(blockHash, inclusionProof, txOutIndex);
            if (!BtcProof.compareScripts(outputScript, txOutScript)) revert ScriptMismatch(outputScript, txOutScript);

            // Get the expected op_return script: OP_RETURN | PUSH_(embeddedData.length) | embeddedData
            bytes memory opReturnData = BtcScript.embedOpReturn(embeddedData);
            if (!BtcProof.compareScripts(opReturnData, nextOutputScript)) {
                revert ScriptMismatch(opReturnData, nextOutputScript);
            }
            return sats;
        }

        // This function validates that blockHash == hash(inclusionProof.blockHeader);
        (sats, txOutScript) = BtcProof.validateTx(blockHash, inclusionProof, txOutIndex);
        if (!BtcProof.compareScripts(outputScript, txOutScript)) revert ScriptMismatch(outputScript, txOutScript);
    }

    /**
     * @notice Verifies an output to have been paid on Bitcoin.
     * @param orderId Input chain order identifier.
     * @param output Output to prove has been filled.
     * @param blockNum Bitcoin block number of block that included the transaction that fills the output.
     * @param inclusionProof Context required to validate an output has been filled.
     * @param txOutIndex Index of the txo that fills the output.
     * @param timestamp Timestamp of fill. Not authenticated.
     */
    function _verify(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIndex,
        uint32 timestamp
    ) internal {
        if (timestamp + CAN_VALIDATE_OUTPUTS_FOR < uint32(block.timestamp)) revert TooLate();

        bytes32 token = output.token;
        uint256 sats = _validateUnderlyingPayment(
            _getNumConfirmations(token),
            blockNum,
            inclusionProof,
            txOutIndex,
            _bitcoinScript(token, output.recipient),
            output.callbackData
        );
        if (sats != output.amount) revert BadAmount(); // Exact amount is checked to protect against "double spends".

        bytes32 solver = _resolveClaimed(timestamp, orderId, output);

        bytes32 fillDescriptionHash =
            keccak256(MandateOutputEncodingLib.encodeFillDescription(solver, orderId, uint32(timestamp), output));
        _attestations[block.chainid][output.oracle][address(this).toIdentifier()][fillDescriptionHash] = true;

        emit OutputFilled(orderId, solver, uint32(timestamp), output, output.amount);
        emit OutputVerified(inclusionProof.txId);
    }

    /**
     * @notice Wrapper around _verify that attached a timestamp to the verification context.
     * @param orderId Input chain order identifier.
     * @param output Output to prove has been filled.
     * @param blockNum Bitcoin block number of block that included the transaction that fills the output.
     * @param inclusionProof Context required to validate an output has been filled.
     * @param txOutIndex Index of the output in the transaction being proved.
     */
    function _verifyAttachTimestamp(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIndex
    ) internal {
        // _validateUnderlyingPayment checks if inclusionProof.blockHeader == 80.
        uint32 timestamp = _getTimestampOfBlock(inclusionProof.blockHeader);
        _verify(orderId, output, blockNum, inclusionProof, txOutIndex, timestamp);
    }

    /**
     * @notice Function overload of _verify but allows specifying an older block.
     * @param orderId Input chain order identifier.
     * @param output Output to prove has been filled.
     * @param blockNum Bitcoin block number of block that included the transaction that fills the output.
     * @param inclusionProof Context required to validate an output has been filled.
     * @param txOutIndex Index of the output in the transaction being proved.
     * @param previousBlockHeader Header of the block before blockNum. Timestamp will be collected from this header.
     */
    function _verifyAttachTimestamp(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIndex,
        bytes calldata previousBlockHeader
    ) internal {
        // _validateUnderlyingPayment checks if inclusionProof.blockHeader == 80.
        uint32 timestamp = _getTimestampOfPreviousBlock(previousBlockHeader, inclusionProof.blockHeader);
        _verify(orderId, output, blockNum, inclusionProof, txOutIndex, timestamp);
    }

    /**
     * @notice Validate an output has been included in a block with appropriate confirmation.
     * @param orderId Input chain order identifier.
     * @param output Output to prove has been filled.
     * @param blockNum Bitcoin block number of block that included the transaction that fills the output.
     * @param inclusionProof Context required to validate an output has been filled.
     * @param txOutIndex Index of the output in the transaction being proved.
     */
    function verify(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIndex
    ) external {
        _verifyAttachTimestamp(orderId, output, blockNum, inclusionProof, txOutIndex);
    }

    /**
     * @notice Validate an output has been included in a block with appropriate confirmation using a timestamp from a
     * older block.
     * @dev This function technically extends the verification of outputs 1 block (~10 minutes)
     * into the past beyond what _validateTimestamp would ordinary allow.
     * The purpose is to protect against slow block mining. Even if it took days to mine 1 block for a transaction,
     * it would still be possible to include the proof with a valid time. (assuming the oracle period isn't over yet).
     * @param orderId Input chain order identifier.
     * @param output Output to prove has been filled.
     * @param blockNum Bitcoin block number of block that included the transaction that fills the output.
     * @param inclusionProof Context required to validate an output has been filled.
     * @param txOutIndex Index of the output in the transaction being proved.
     * @param previousBlockHeader Header of the block before blockNum. Timestamp will be collected from this header.
     */
    function verify(
        bytes32 orderId,
        MandateOutput calldata output,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIndex,
        bytes calldata previousBlockHeader
    ) external {
        _verifyAttachTimestamp(orderId, output, blockNum, inclusionProof, txOutIndex, previousBlockHeader);
    }

    // --- Optimistic Resolution and Order-Preclaiming --- //
    // For Bitcoin, it is required that outputs are claimed before they are delivered.
    // This is because it is impossible to block duplicate deliveries on Bitcoin in the same way
    // that is possible with EVM. (Actually, not true. It is just much more expensive – any-spend anchors).

    /**
     * @notice Returns the solver associated with the claim.
     * @dev Allows reentry calls. Does not honor the check effect pattern globally.
     * @param fillTimestamp Timestamp of fill. Not authenticated.
     * @param orderId Input chain order identifier.
     * @param output Output to prove has been filled.
     * @return solver The identifier for the solver that filled claimed the roder.
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

        address claimant = claimedOrder.claimant;
        uint96 multiplier = claimedOrder.multiplier;
        uint32 disputeTimestamp = claimedOrder.disputeTimestamp;
        address disputer = claimedOrder.disputer;

        // - fillTimestamp >= claimTimestamp is not checked and it is assumed the 1 day validation window is sufficient
        // to check that the transaction was made to fill this output.
        if (claimant != address(0) && (disputer == address(0) || fillTimestamp <= disputeTimestamp)) {
            bool disputed = disputer != address(0);

            // Delete storage; no re-entry.
            delete claimedOrder.multiplier;
            delete claimedOrder.claimTimestamp;
            delete claimedOrder.claimant;
            delete claimedOrder.disputer;
            delete claimedOrder.disputeTimestamp;

            uint256 collateralAmount = output.amount * multiplier;
            uint256 disputeCost = collateralAmount - collateralAmount / DISPUTED_ORDER_FEE_FRACTION;
            collateralAmount =
                disputed ? collateralAmount * (CHALLENGER_COLLATERAL_FACTOR + 1) - disputeCost : collateralAmount;

            SafeERC20.safeTransfer(COLLATERAL_TOKEN, claimant, collateralAmount);
            if (disputed && 0 < disputeCost) {
                SafeERC20.safeTransfer(COLLATERAL_TOKEN, DISPUTED_ORDER_FEE_DESTINATION, disputeCost);
            }
        }
    }

    /**
     * @notice Claims an order.
     * @param solver Identifier to set as the solver.
     * @param orderId Input chain order identifier.
     * @param output The output to verify.
     */
    function claim(
        bytes32 solver,
        bytes32 orderId,
        MandateOutput calldata output
    ) external {
        if (solver == bytes32(0)) revert ZeroValue();
        if (orderId == bytes32(0)) revert ZeroValue();
        OutputVerificationLib._isThisChain(output.chainId);
        OutputVerificationLib._isThisOutputSettler(output.settler);

        bytes32 outputId = _outputIdentifier(output);
        ClaimedOrder storage claimedOrder = _claimedOrder[orderId][outputId];
        if (claimedOrder.solver != bytes32(0)) revert AlreadyClaimed(claimedOrder.solver);
        uint256 multiplier = _readMultiplier(output.context);

        claimedOrder.solver = solver;
        claimedOrder.claimTimestamp = uint32(block.timestamp);
        claimedOrder.claimant = msg.sender;
        claimedOrder.multiplier = uint64(multiplier);
        // The above lines acts as a local re-entry guard. External calls are now allowed.

        uint256 collateralAmount = output.amount * multiplier;
        SafeERC20.safeTransferFrom(COLLATERAL_TOKEN, msg.sender, address(this), collateralAmount);

        emit OutputClaimed(orderId, outputId);
    }

    /**
     * @notice Dispute an order.
     * @param orderId Order Identifier
     * @param output Output description of the order to dispute.
     */
    function dispute(
        bytes32 orderId,
        MandateOutput calldata output
    ) external {
        bytes32 outputId = _outputIdentifier(output);

        ClaimedOrder storage claimedOrder = _claimedOrder[orderId][outputId];
        if (claimedOrder.claimant == address(0)) revert NotClaimed();
        if (claimedOrder.claimTimestamp + DISPUTE_PERIOD < block.timestamp) revert TooLate();

        if (claimedOrder.disputer != address(0)) revert AlreadyDisputed(claimedOrder.disputer);
        claimedOrder.disputer = msg.sender;

        uint32 currentTimestamp = uint32(block.timestamp);
        uint32 inclusionTimestamp = uint32(claimedOrder.claimTimestamp + MIN_TIME_FOR_INCLUSION);
        // Allow for a minimum amount of time to get the transaction included.
        claimedOrder.disputeTimestamp = currentTimestamp < inclusionTimestamp ? inclusionTimestamp : currentTimestamp;

        uint256 collateralAmount = output.amount * claimedOrder.multiplier;
        collateralAmount = collateralAmount * CHALLENGER_COLLATERAL_FACTOR;
        SafeERC20.safeTransferFrom(COLLATERAL_TOKEN, msg.sender, address(this), collateralAmount);

        emit OutputDisputed(orderId, outputId);
    }

    /**
     * @notice Optimistically verify an order if the order has not been disputed.
     * @param orderId Order Identifier
     * @param output Output description of the order to dispute.
     */
    function optimisticallyVerify(
        bytes32 orderId,
        MandateOutput calldata output
    ) external {
        bytes32 outputId = _outputIdentifier(output);

        ClaimedOrder storage claimedOrder = _claimedOrder[orderId][outputId];
        if (claimedOrder.claimant == address(0)) revert NotClaimed();
        if (claimedOrder.claimTimestamp + DISPUTE_PERIOD >= block.timestamp) revert TooEarly();
        if (claimedOrder.disputer != address(0)) revert Disputed();

        bytes32 solver = claimedOrder.solver;
        bytes32 outputHash =
            keccak256(MandateOutputEncodingLib.encodeFillDescription(solver, orderId, uint32(block.timestamp), output));
        _attestations[block.chainid][output.oracle][address(this).toIdentifier()][outputHash] = true;
        emit OutputFilled(orderId, solver, uint32(block.timestamp), output, output.amount);

        address claimant = claimedOrder.claimant;
        uint256 multiplier = claimedOrder.multiplier;

        delete claimedOrder.multiplier;
        delete claimedOrder.claimTimestamp;
        delete claimedOrder.claimant;
        delete claimedOrder.disputer;
        delete claimedOrder.disputeTimestamp;
        // The above lines acts as a local re-entry guard. External calls are now allowed.

        uint256 collateralAmount = output.amount * multiplier;
        SafeERC20.safeTransfer(COLLATERAL_TOKEN, claimant, collateralAmount);

        emit OutputOptimisticallyVerified(orderId, outputId);
    }

    /**
     * @notice Finalise a dispute if the order hasn't been proven.
     * @param orderId Order Identifier
     * @param output Output description of the order to dispute.
     */
    function finaliseDispute(
        bytes32 orderId,
        MandateOutput calldata output
    ) external {
        bytes32 outputId = _outputIdentifier(output);

        ClaimedOrder storage claimedOrder = _claimedOrder[orderId][outputId];
        address disputer = claimedOrder.disputer;
        uint256 multiplier = claimedOrder.multiplier;
        if (disputer == address(0)) revert NotDisputed();

        uint256 numConfirmations = _getNumConfirmations(output.token);
        uint256 proofPeriod = _getProofPeriod(numConfirmations);
        uint256 disputeTimestamp = claimedOrder.disputeTimestamp;

        if (disputeTimestamp + proofPeriod >= block.timestamp) revert TooEarly();

        delete claimedOrder.multiplier;
        delete claimedOrder.claimTimestamp;
        delete claimedOrder.claimant;
        delete claimedOrder.disputer;
        delete claimedOrder.disputeTimestamp;
        // The above lines acts as a local re-entry guard. External calls are now allowed.

        uint256 collateralAmount = output.amount * multiplier;
        uint256 disputeCost = collateralAmount - collateralAmount / DISPUTED_ORDER_FEE_FRACTION;
        collateralAmount = collateralAmount * (CHALLENGER_COLLATERAL_FACTOR + 1);
        SafeERC20.safeTransfer(COLLATERAL_TOKEN, disputer, collateralAmount - disputeCost);
        if (0 < disputeCost) SafeERC20.safeTransfer(COLLATERAL_TOKEN, DISPUTED_ORDER_FEE_DESTINATION, disputeCost);

        emit OutputDisputeFinalised(orderId, outputId);
    }
}
