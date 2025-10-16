// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { IBtcPrism } from "./interfaces/IBtcPrism.sol";
import { IBtcTxVerifier } from "./interfaces/IBtcTxVerifier.sol";

import { InvalidProof, NoBlock, TooFewConfirmations } from "./interfaces/IBtcTxVerifier.sol";
import { BtcProof, BtcTxProof, ScriptMismatch } from "./library/BtcProof.sol";

// BtcVerifier implements a merkle proof that a Bitcoin payment succeeded. It
// uses BtcPrism as a source of truth for which Bitcoin block hashes are in the
// canonical chain.
contract BtcTxVerifier is IBtcTxVerifier {
    IBtcPrism public immutable prism;

    constructor(
        IBtcPrism _prism
    ) {
        prism = _prism;
    }

    function _verifyPayment(
        uint256 minConfirmations,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx,
        bytes calldata outputScript
    ) internal view returns (uint256 sats) {
        {
            uint256 currentHeight = prism.getLatestBlockHeight();

            if (currentHeight < blockNum) revert NoBlock(currentHeight, blockNum);

            unchecked {
                if (currentHeight + 1 - blockNum < minConfirmations) {
                    revert TooFewConfirmations(currentHeight + 1 - blockNum, minConfirmations);
                }
            }
        }

        bytes32 blockHash = prism.getBlockHash(blockNum);

        bytes memory txOutScript;
        (sats, txOutScript) = BtcProof.validateTx(blockHash, inclusionProof, txOutIx);

        if (!BtcProof.compareScriptsCM(outputScript, txOutScript)) revert ScriptMismatch(outputScript, txOutScript);
    }

    function verifyPayment(
        uint256 minConfirmations,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx,
        bytes calldata outputScript
    ) external view returns (uint256 sats) {
        return _verifyPayment(minConfirmations, blockNum, inclusionProof, txOutIx, outputScript);
    }

    function _verifyOrdinal(
        uint256 minConfirmations,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txInId,
        uint32 txInPrevTxIndex,
        bytes calldata outputScript,
        uint256 amountSats
    ) internal view returns (bool) {
        {
            uint256 currentHeight = prism.getLatestBlockHeight();

            if (currentHeight < blockNum) revert NoBlock(currentHeight, blockNum);

            unchecked {
                if (currentHeight + 1 - blockNum < minConfirmations) {
                    revert TooFewConfirmations(currentHeight + 1 - blockNum, minConfirmations);
                }
            }
        }

        bytes32 blockHash = prism.getBlockHash(blockNum);

        if (!BtcProof.validateOrdinalTransfer(
                blockHash, inclusionProof, txInId, txInPrevTxIndex, outputScript, amountSats
            )) revert InvalidProof();

        return true;
    }

    function verifyOrdinal(
        uint256 minConfirmations,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txInId,
        uint32 txInPrevTxIndex,
        bytes calldata outputScript,
        uint256 amountSats
    ) external view returns (bool) {
        return
            _verifyOrdinal(
                minConfirmations, blockNum, inclusionProof, txInId, txInPrevTxIndex, outputScript, amountSats
            );
    }
}
