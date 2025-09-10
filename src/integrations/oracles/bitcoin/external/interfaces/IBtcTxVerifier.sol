// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { BtcTxProof } from "./BtcStructs.sol";
import { IBtcPrism } from "./IBtcPrism.sol";

error NoBlock(uint256 currentHeight, uint256 proposedHeight);
error TooFewConfirmations(uint256 current, uint256 wanted);
error InvalidProof();

/**
 * @notice Verifies Bitcoin transaction proofs.
 */
interface IBtcTxVerifier {
    /**
     * @notice Verifies that the a transaction cleared, and returns the paid amount
     *         to outputScript. Specifically, verifies a proof that the tx was
     *         in block N, and that block N has at least M confirmations.
     */
    function verifyPayment(
        uint256 minConfirmations,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx,
        bytes calldata outputScript
    ) external view returns (uint256 amountSats);

    /**
     * @notice Returns the underlying prism associated with this verifier.
     */
    function prism() external view returns (IBtcPrism);

    /**
     * @notice Verifies that the a transaction cleared, sending a specific ordinal to
     *         a given address. Specifically, verifies a proof that the tx was
     *         in block N, and that block N has at least M confirmations.
     */
    function verifyOrdinal(
        uint256 minConfirmations,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txInId,
        uint32 txInPrevTxIndex,
        bytes calldata outputScript,
        uint256 amountSats
    ) external view returns (bool);
}
