// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { Endian } from "../Endian.sol";
import { BitcoinTx, BitcoinTxIn, BitcoinTxOut, BtcTxProof } from "../interfaces/BtcStructs.sol";

error TxMerkleRootMismatch(bytes32 blockTxRoot, bytes32 txRoot);
error ScriptMismatch(bytes expected, bytes actual);
error AmountMismatch(uint256 txoSats, uint256 expected);
error TxIDMismatch(bytes32 rawTxId, bytes32 txProofId);
error BlockHashMismatch(bytes32 blockHeader, bytes32 givenBlockHash);

error InvalidTxInHash(uint256 expected, uint256 actual);
error InvalidTxInIndex(uint32 expected, uint32 actual);

error TxIndexNot0(uint256 index);
error InvalidFormat();

error InvalidMerkleNodePair(uint256, bytes32, bytes32);

// BtcProof provides functions to prove things about Bitcoin transactions.
// Verifies merkle inclusion proofs, transaction IDs, and payment details.
library BtcProof {
    /**
     * @dev Validates that a given payment appears under a given block hash.
     *
     * This verifies all of the following:
     * 2. Raw transaction hashes to the given transaction ID.
     * 3. Transaction ID appears under transaction root (Merkle proof).
     * 4. Transaction root is part of the block header.
     * 5. Block header hashes to a given block hash.
     *
     * The caller must separately verify that the block hash is in the chain.
     *
     * Always returns true or reverts with a descriptive reason.
     */
    function subValidate(
        bytes32 blockHash,
        BtcTxProof calldata txProof
    ) internal pure returns (BitcoinTx memory parsedTx) {
        // 5. Block header to block hash

        bytes calldata proofBlockHeader = txProof.blockHeader;
        bytes32 blockHeaderBlockHash = getBlockHash(proofBlockHeader);
        if (blockHeaderBlockHash != blockHash) revert BlockHashMismatch(blockHeaderBlockHash, blockHash);

        // 4. and 3. Transaction ID included in block
        bytes32 txRoot = getTxMerkleRoot(txProof.txId, txProof.txIndex, txProof.txMerkleProof);
        bytes32 blockTxRoot = getBlockTxMerkleRoot(proofBlockHeader);
        if (blockTxRoot != txRoot) revert TxMerkleRootMismatch(blockTxRoot, txRoot);

        bytes calldata rawTx = txProof.rawTx;
        // 2. Raw transaction to TxID
        bytes32 rawTxId = getTxID(rawTx);
        if (rawTxId != txProof.txId) revert TxIDMismatch(rawTxId, txProof.txId);

        // Parse raw transaction for further validation.
        parsedTx = parseBitcoinTx(rawTx);

        // Check if format is valid
        if (!parsedTx.validFormat) revert InvalidFormat();
        return parsedTx;
    }

    /**
     * @dev Validates that a given payment appears under a given block hash.
     *
     * This verifies all of the following:
     * 1. Raw transaction contains an output to txOutIx.
     *
     * The caller must separately verify that the block hash is in the chain.
     *
     * Always returns true or reverts with a descriptive reason.
     */
    function validateTx(
        bytes32 blockHash,
        BtcTxProof calldata txProof,
        uint256 txOutIx
    ) internal pure returns (uint256 sats, bytes memory outputScript) {
        // 1. Finally, validate raw transaction and get relevant values.
        BitcoinTx memory parsedTx = subValidate(blockHash, txProof);
        BitcoinTxOut memory txo = parsedTx.outputs[txOutIx];

        outputScript = txo.script;
        sats = txo.valueSats;
    }

    /**
     * @dev Fork of validateTx that also returns the output script of the next output.
     * Will revert if no output exists after the specific output (for sats / output script).
     * @param returnScript Note that this may not actually be a return script. Please validate that the
     * structure is correct.
     */
    function validateTxData(
        bytes32 blockHash,
        BtcTxProof calldata txProof,
        uint256 txOutIx
    ) internal pure returns (uint256 sats, bytes memory outputScript, bytes memory returnScript) {
        // 1. Finally, validate raw transaction and get relevant values.
        BitcoinTx memory parsedTx = subValidate(blockHash, txProof);
        BitcoinTxOut memory txo = parsedTx.outputs[txOutIx];

        outputScript = txo.script;
        sats = txo.valueSats;
        unchecked {
            // Load the return script from the next output of the transaction.
            // If there is no next output, this will fail.
            returnScript = parsedTx.outputs[txOutIx + 1].script;
        }
    }

    /**
     * @dev Validates that a given transfer of ordinal(s) appears under a given block hash.
     *
     * This verifies all of the following:
     * 1. Raw transaction contains a specific input (at index 0) that pays more than X to specific output (at index 0).
     *
     * The caller must separately verify that the block hash is in the chain.
     *
     * Always returns true or reverts with a descriptive reason.
     */
    function validateOrdinalTransfer(
        bytes32 blockHash,
        BtcTxProof calldata txProof,
        uint256 txInId,
        uint32 txInPrevTxIndex,
        bytes calldata outputScript,
        uint256 satoshisExpected
    ) internal pure returns (bool) {
        // 1. Finally, validate raw transaction correctly transfers the ordinal(s).
        // Parse transaction
        BitcoinTx memory parsedTx = subValidate(blockHash, txProof);
        BitcoinTxIn memory txInput = parsedTx.inputs[0];
        // Check if correct input transaction is used.
        if (txInId != txInput.prevTxID) revert InvalidTxInHash(txInId, txInput.prevTxID);
        // Check if correct index of that transaction is used.
        if (txInPrevTxIndex != txInput.prevTxIndex) revert InvalidTxInIndex(txInPrevTxIndex, txInput.prevTxIndex);

        BitcoinTxOut memory txo = parsedTx.outputs[0];
        // if the length are less than 32, then use bytes32 to compare.
        if (!compareScriptsCM(outputScript, txo.script)) revert ScriptMismatch(outputScript, txo.script);

        // We allow for sending more because of the dust limit which may cause problems.
        if (txo.valueSats < satoshisExpected) revert AmountMismatch(txo.valueSats, satoshisExpected);

        // We've verified that blockHash contains a transaction with correct script
        // that sends at least satoshisExpected to the given hash.
        return true;
    }

    /**
     * @dev Compare 2 scripts, if they are less than 32 bytes directly compare otherwise by hash.
     */
    function compareScriptsCC(
        bytes calldata a,
        bytes calldata b
    ) internal pure returns (bool) {
        if (a.length <= 32 && b.length <= 32) return bytes32(a) == bytes32(b);
        else return keccak256(a) == keccak256(b);
    }

    /**
     * @dev Compare 2 scripts, if they are less than 32 bytes directly compare otherwise by hash.
     */
    function compareScripts(
        bytes memory a,
        bytes memory b
    ) internal pure returns (bool) {
        if (a.length <= 32 && b.length <= 32) return bytes32(a) == bytes32(b);
        else return keccak256(a) == keccak256(b);
    }

    /**
     * @dev Compare 2 scripts, if they are less than 32 bytes directly compare otherwise by hash.
     */
    function compareScriptsCM(
        bytes calldata a,
        bytes memory b
    ) internal pure returns (bool) {
        if (a.length <= 32 && b.length <= 32) return bytes32(a) == bytes32(b);
        else return keccak256(a) == keccak256(b);
    }

    /**
     * @dev Compute a block hash given a block header.
     */
    function getBlockHash(
        bytes calldata blockHeader
    ) internal pure returns (bytes32) {
        require(blockHeader.length == 80);
        bytes32 ret = sha256(bytes.concat(sha256(blockHeader)));
        return bytes32(Endian.reverse256(uint256(ret)));
    }

    /**
     * @dev Get the transactions merkle root given a block header.
     */
    function getBlockTxMerkleRoot(
        bytes calldata blockHeader
    ) internal pure returns (bytes32 merkleroot) {
        require(blockHeader.length == 80);
        assembly ("memory-safe") {
            // merkleroot = bytes32(blockHeader[36:68]);
            merkleroot := calldataload(add(blockHeader.offset, 36))
        }
    }

    /**
     * @dev Recomputes the transactions root given a merkle proof.
     * If 2 nodes together (64 bytes) makes a validly formatted transaction, then the merkle proof
     * cannot be verified. If these nodes are at the top of the tree, the merkle tree is entirely invalid.
     * However, this is not an issue since in just the first 5 bytes, only 1-3 valid combinations exists
     * (0x0100000001-0x0300000001)
     * That means that only 3 in 1099511627775 nodes will be able to continue beyond the first check.
     * Every block contains less than 5000 transactions, 5000*6*24*365*3/1099511627775 = 0.07%.
     * So each year there is 0.07% chance that a single node may accidentally be invalided by just a single check of the
     * first 5 bytes. There are even further restrictions so the chance that 2 random nodes combine to from to make a
     * valid transaction is not important. (for example, 1 more varInt needs to be 01 or 00, and 2 varints needs to sum
     * to less than 8)
     * These 2 contains adds 127755 invalid options so the total is 3/140468108006395125 => ≈0% chance
     */
    function getTxMerkleRoot(
        bytes32 txId,
        uint256 txIndex,
        bytes calldata siblings
    ) internal pure returns (bytes32) {
        unchecked {
            bytes32 ret = bytes32(Endian.reverse256(uint256(txId)));
            uint256 len = siblings.length / 32;

            // This merkle calculation is vulnerable to an attack where a transaction is converted into a leaf.
            // this is possible because it is possible to create a valid 64 bytes (2*32 bytes) transaction and
            // leaves are hashes with the same algorithm as nodes.
            //
            for (uint256 i = 0; i < len; ++i) {
                bytes32 s;
                assembly ("memory-safe") {
                    // uint256(bytes32(siblings[i * 32:(i + 1) * 32]))
                    s := calldataload(add(siblings.offset, mul(i, 32))) // i is small.
                }
                s = bytes32(Endian.reverse256(uint256(s)));
                bytes memory pair = txIndex & 1 == 0 ? abi.encodePacked(ret, s) : abi.encodePacked(s, ret);
                // Check if the pair is a valid transaction:
                if (checkIfBitcoinTransaction(pair)) revert InvalidMerkleNodePair(txIndex, ret, s);
                ret = doubleSha(pair);
                txIndex = txIndex >> 1;
            }
            if (txIndex != 0) revert TxIndexNot0(txIndex);
            return ret;
        }
    }

    /**
     * @dev Computes the ubiquitous Bitcoin SHA256(SHA256(x))
     */
    function doubleSha(
        bytes memory buf
    ) internal pure returns (bytes32) {
        return sha256(bytes.concat(sha256(buf)));
    }

    /**
     * @dev Recomputes the transaction ID for a raw transaction.
     */
    function getTxID(
        bytes calldata rawTransaction
    ) internal pure returns (bytes32) {
        bytes32 ret = doubleSha(rawTransaction);
        return bytes32(Endian.reverse256(uint256(ret)));
    }

    /**
     * @dev Parses a HASH-SERIALIZED Bitcoin transaction.
     *      This means no flags and no segwit witnesses.
     *
     *      Should only be done on verified transactions as the unchecked block allows
     *      for user controlled overflow but only if bad data is provided. A valid Bitcoin
     *      transaction will never behave like that.
     */
    function parseBitcoinTx(
        bytes calldata rawTx
    ) internal pure returns (BitcoinTx memory ret) {
        // This unchecked block is safe because the offset is measured in the size of rawTx.
        // as such, it will be lower than type(uint256).max
        // Some people may try to make the varint fail but that isn't a valid Bitcoin transaction.
        // as such, it is already invalid.
        unchecked {
            ret.version = Endian.reverse32(uint32(bytes4(rawTx[0:4])));
            if (ret.version < 1 || ret.version > 2) return ret; // invalid version

            // Read transaction inputs
            uint256 offset = 4;
            uint256 nInputs;
            (nInputs, offset) = readVarInt(rawTx, offset);
            ret.inputs = new BitcoinTxIn[](nInputs);
            for (uint256 i = 0; i < nInputs; ++i) {
                BitcoinTxIn memory txIn;
                txIn.prevTxID = Endian.reverse256(uint256(bytes32(rawTx[offset:offset += 32])));
                txIn.prevTxIndex = Endian.reverse32(uint32(bytes4(rawTx[offset:offset += 4])));
                uint256 nInScriptBytes;
                (nInScriptBytes, offset) = readVarInt(rawTx, offset);
                txIn.script = rawTx[offset:offset += nInScriptBytes];
                txIn.seqNo = Endian.reverse32(uint32(bytes4(rawTx[offset:offset += 4])));
                ret.inputs[i] = txIn;
            }

            // Read transaction outputs
            uint256 nOutputs;
            (nOutputs, offset) = readVarInt(rawTx, offset);
            ret.outputs = new BitcoinTxOut[](nOutputs);
            for (uint256 i = 0; i < nOutputs; ++i) {
                BitcoinTxOut memory txOut;
                txOut.valueSats = Endian.reverse64(uint64(bytes8(rawTx[offset:offset += 8])));
                uint256 nOutScriptBytes;
                (nOutScriptBytes, offset) = readVarInt(rawTx, offset);
                txOut.script = rawTx[offset:offset += nOutScriptBytes];
                ret.outputs[i] = txOut;
            }

            // Finally, read locktime, the last four bytes in the tx.
            ret.locktime = Endian.reverse32(uint32(bytes4(rawTx[offset:offset += 4])));
            if (offset != rawTx.length) return ret; // Extra data at end of transaction.

            // Parsing complete, sanity checks passed, return success.
            ret.validFormat = true;
            return ret;
        }
    }

    /**
     * @notice Checks if bytes may be a Bitcoin transaction.
     * If at any point
     * @dev Returns false if rawTx is less than 56.
     * If this needs to be used to verify transaction larger than 64 bytes, please recheck every single line.
     * For example, it is assumed that varints can't be larger than 0xfe == 256.
     */
    function checkIfBitcoinTransaction(
        bytes memory rawTx
    ) internal pure returns (bool) {
        uint256 size = rawTx.length;
        if (size < 56) return false;

        uint256 version = uint8(bytes1(rawTx[0]));
        if (version < 1 || version > 2) return false; // invalid version
            // Then check that the next 3 bytes are 0.
        if (bytes1(rawTx[1]) != bytes1(0)) return false;
        if (bytes1(rawTx[2]) != bytes1(0)) return false;
        if (bytes1(rawTx[3]) != bytes1(0)) return false;
        // We need to read the next varint. Importantly,
        // if the varint is larger than 1 byte (>= 0xfd) then we can instant disqualify it.
        uint256 nInputs = uint8(bytes1(rawTx[4]));
        uint256 offset = 5;
        // Each transaction adds at least 41 bytes. Let check if there is space.
        if (nInputs * (32 + 4 + 4 + 1) + offset > size) return false;

        // We need to check if the input(s) is valid. Sadly, a lot of these bytes
        // can be pretty much anything.
        for (uint256 i = 0; i < nInputs; ++i) {
            // prevTxID doesn't matter.
            offset += 32;
            // prevTxIndex doesn't matter.
            offset += 4;
            // Like previously, if the varint is larger than 1 byte (>= 0xfd) we can instantly disqualify it.
            uint256 nInScriptBytes = uint8(bytes1(rawTx[offset]));
            if (nInScriptBytes + offset > size) return false;
            offset += nInScriptBytes + 1; // (+1 from varInt)
                // seqNo doesn't matter
            offset += 4;
        }

        // varInt again.
        uint256 nOutputs = uint8(bytes1(rawTx[offset]));
        if (nOutputs * (8 + 1) + offset > size) return false;
        offset += 1;
        for (uint256 i = 0; i < nOutputs; ++i) {
            // valueSats doesn't matter
            offset += 8;
            // varInt again.
            uint256 nOutScriptBytes = uint8(bytes1(rawTx[offset]));
            if (nOutScriptBytes + offset > size) return false;
            offset += nOutScriptBytes + 1; // (+1 from varInt)
        }

        // Finally, read locktime, the last four bytes in the tx.
        offset += 4;
        if (offset != size) return false;
        return true;
    }

    /**
     * Reads a Bitcoin-serialized varint = a u256 serialized in 1-9 bytes.
     */
    function readVarInt(
        bytes calldata buf,
        uint256 offset
    ) internal pure returns (uint256 val, uint256 newOffset) {
        // The offset is bounded in size.
        unchecked {
            uint8 pivot = uint8(buf[offset]);
            if (pivot < 0xfd) {
                val = pivot;
                return (val, newOffset = offset + 1);
            }
            if (pivot == 0xfd) {
                bytes2 val2;
                assembly ("memory-safe") {
                    // val16 = uint16(bytes2(buf[offset + 1:offset+3]));
                    val2 := calldataload(add(buf.offset, add(offset, 1)))
                }
                val = Endian.reverse16(uint16(val2));
                return (val, newOffset = offset + 3);
            }
            if (pivot == 0xfe) {
                bytes4 val4;
                assembly ("memory-safe") {
                    // val32 = uint32(bytes4(buf[offset + 1:offset+5]));
                    val4 := calldataload(add(buf.offset, add(offset, 1)))
                }
                val = Endian.reverse32(uint32(val4));
                return (val, newOffset = offset + 5);
            }
            // pivot == 0xff
            bytes8 val8;
            assembly ("memory-safe") {
                // val64 = uint64(bytes8(buf[offset + 1:offset+9]));
                val8 := calldataload(add(buf.offset, add(offset, 1)))
            }
            val = Endian.reverse64(uint64(val8));
            return (val, newOffset = offset + 9);
        }
    }
}
