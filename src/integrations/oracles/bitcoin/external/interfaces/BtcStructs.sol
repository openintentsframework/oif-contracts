// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice Proof that a transaction (rawTx) is in a given block.
 */
struct BtcTxProof {
    /**
     * @notice 80-byte block header.
     */
    bytes blockHeader;
    /**
     * @notice Bitcoin transaction ID, equal to SHA256(SHA256(rawTx))
     */
    // This is not gas-optimized--we could omit it and compute from rawTx. But
    //s the cost is minimal, and keeping it allows better revert messages.
    bytes32 txId;
    /**
     * @notice Index of transaction within the block.
     */
    uint256 txIndex;
    /**
     * @notice Merkle proof. Concatenated sibling hashes, 32*n bytes.
     */
    bytes txMerkleProof;
    /**
     * @notice Raw transaction, HASH-SERIALIZED, no witnesses.
     */
    bytes rawTx;
}

/**
 * @dev A parsed (but NOT fully validated) Bitcoin transaction.
 */
struct BitcoinTx {
    /**
     * @dev Whether we successfully parsed this Bitcoin TX, valid version etc.
     *      Does NOT check signatures or whether inputs are unspent.
     */
    bool validFormat;
    /**
     * @dev Version. Must be 1 or 2.
     */
    uint32 version;
    /**
     * @dev Each input spends a previous UTXO.
     */
    BitcoinTxIn[] inputs;
    /**
     * @dev Each output creates a new UTXO.
     */
    BitcoinTxOut[] outputs;
    /**
     * @dev Locktime. Either 0 for no lock, blocks if <500k, or seconds.
     */
    uint32 locktime;
}

struct BitcoinTxIn {
    /**
     * @dev Previous transaction.
     */
    uint256 prevTxID;
    /**
     * @dev Specific output from that transaction.
     */
    uint32 prevTxIndex;
    /**
     * @dev Mostly useless for tx v1, BIP68 Relative Lock Time for tx v2.
     */
    uint32 seqNo;
    /**
     * @dev Input script, spending a previous UTXO.
     */
    bytes script;
}

struct BitcoinTxOut {
    /**
     * @dev TXO value, in satoshis
     */
    uint64 valueSats;
    /**
     * @dev Output script.
     */
    bytes script;
}
