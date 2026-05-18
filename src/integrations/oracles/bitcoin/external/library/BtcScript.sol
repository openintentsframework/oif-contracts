// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "./BitcoinOpcodes.sol";

enum AddressType {
    UNKNOWN,
    P2PKH,
    P2SH,
    P2WPKH,
    P2WSH,
    P2TR
}

/**
 * @notice A Parsed Script address
 */
struct BitcoinAddress {
    AddressType addressType;
    /**
     * @dev P2PKH, address hash or P2SH, script hash. Is empty if segwit transaction
     */
    bytes32 implementationHash;
}

/**
 * @notice This contract implement helper functions for external actors
 * when they encode or decode Bitcoin scripts.
 * @dev This contract is not intended for on-chain calls.
 */
library BtcScript {
    error ScriptTooLong(uint256 length);
    error NotImplemented();

    //--- Bitcoin Script Decode Helpers ---//

    /**
     * @notice Global helper for decoding Bitcoin addresses
     */
    function getBitcoinAddress(
        bytes calldata script
    ) internal pure returns (BitcoinAddress memory btcAddress) {
        // Check if P2PKH
        bytes1 firstByte = script[0];
        if (firstByte == OP_DUB) {
            if (script.length == P2PKH_SCRIPT_LENGTH) {
                btcAddress.implementationHash = decodeP2PKH(script);
                btcAddress.addressType = btcAddress.implementationHash == 0 ? AddressType.UNKNOWN : AddressType.P2PKH;
                return btcAddress;
            }
        } else if (firstByte == OP_HASH160) {
            if (script.length == P2SH_SCRIPT_LENGTH) {
                btcAddress.implementationHash = decodeP2SH(script);
                btcAddress.addressType = btcAddress.implementationHash == 0 ? AddressType.UNKNOWN : AddressType.P2SH;
                return btcAddress;
            }
        } else {
            // This is likely a segwit transaction. Try decoding the witness program
            (int8 version, uint8 witnessLength, bytes32 witPro) = decodeWitnessProgram(script);
            if (version != -1) {
                if (version == 0) {
                    btcAddress.addressType = witnessLength == 20
                        ? AddressType.P2WPKH
                        : witnessLength == 32 ? AddressType.P2WSH : AddressType.UNKNOWN;
                } else if (version == 1) {
                    btcAddress.addressType = witnessLength == 32 ? AddressType.P2TR : AddressType.UNKNOWN;
                }
                btcAddress.implementationHash = witPro;
                return btcAddress;
            }
        }
    }

    /**
     * @dev Returns the script hash from a P2SH (pay to script hash) script out.
     * @return hash The recipient script hash, or 0 if verification failed.
     */
    function decodeP2SH(
        bytes calldata script
    ) internal pure returns (bytes20) {
        if (script.length != P2SH_SCRIPT_LENGTH) return 0;
        // OP_HASH <data 20> OP_EQUAL
        if (script[0] != OP_HASH160 || script[1] != PUSH_20 || script[22] != OP_EQUAL) return 0;
        return bytes20(script[P2SH_ADDRESS_START:P2SH_ADDRESS_END]);
    }

    /**
     * @dev Returns the pubkey hash from a P2PKH (pay to pubkey hash) script out.
     * @return hash The recipient public key hash, or 0 if verification failed.
     */
    function decodeP2PKH(
        bytes calldata script
    ) internal pure returns (bytes20) {
        if (script.length != P2PKH_SCRIPT_LENGTH) return 0;
        // OP_DUB OP_HASH160 <pubKeyHash 20> OP_EQUALVERIFY OP_CHECKSIG
        if (
            script[0] != OP_DUB || script[1] != OP_HASH160 || script[2] != PUSH_20 || script[23] != OP_EQUALVERIFY
                || script[24] != OP_CHECKSIG
        ) return 0;
        return bytes20(script[P2PKH_ADDRESS_START:P2PKH_ADDRESS_END]);
    }

    /**
     * @dev Returns the witness program segwit tx.
     * @return version The script version, or -1 if verification failed.
     * @return witnessLength The length of the witness program. Should either be 20 or 32.
     * @return witPro The witness program, or nothing if verification failed.
     */
    function decodeWitnessProgram(
        bytes calldata script
    ) internal pure returns (int8 version, uint8 witnessLength, bytes32 witPro) {
        bytes1 versionBytes1 = script[0];
        if (versionBytes1 == OP_0) {
            version = 0;
        } else if ((uint8(OP_1) <= uint8(versionBytes1) && uint8(versionBytes1) <= uint8(OP_16))) {
            unchecked {
                version = int8(uint8(versionBytes1)) - int8(uint8(OP_1_OFFSET));
            }
        } else {
            return (version = -1, witnessLength = 0, witPro = bytes32(script[0:0]));
        }
        // Check that the length is given and correct.
        uint8 length_byte = uint8(bytes1(script[1]));
        // Check if the length is between 1 and 75. If it is more than 75, we need to decode the length in a different
        // way. Currently, only length 20 and 32 are used.
        if (1 <= length_byte && length_byte <= 75) {
            if (script.length == length_byte + 2) {
                return (version, witnessLength = length_byte, witPro = bytes32(script[2:]));
            }
        }
        return (version = -1, witnessLength = 0, bytes32(script[0:0]));
    }

    //--- Bitcoin Script Encoding Helpers ---//

    /**
     * @notice Global helper for encoding Bitcoin scripts
     */
    function getBitcoinScript(
        BitcoinAddress calldata btcAddress
    ) internal pure returns (bytes memory script) {
        return getBitcoinScript(btcAddress.addressType, btcAddress.implementationHash);
    }

    /**
     * @notice Global helper for encoding Bitcoin scripts
     * @param addressType Enum of address type. Used to specify which script is used.
     * @param implementationHash P2PKH, address hash or P2SH, script hash.
     */
    function getBitcoinScript(
        AddressType addressType,
        bytes32 implementationHash
    ) internal pure returns (bytes memory script) {
        // Check if segwit
        if (addressType == AddressType.P2PKH) return scriptP2PKH(bytes20(implementationHash));
        if (addressType == AddressType.P2SH) return scriptP2SH(bytes20(implementationHash));
        if (addressType == AddressType.P2WPKH) return scriptP2WPKH(bytes20(implementationHash));
        if (addressType == AddressType.P2WSH) return scriptP2WSH(implementationHash);
        if (addressType == AddressType.P2TR) return scriptP2TR(implementationHash);
        revert NotImplemented();
    }

    /// @notice Get the associated script out for a P2PKH address
    function scriptP2PKH(
        bytes20 pHash
    ) internal pure returns (bytes memory) {
        // OP_DUB, OP_HASH160, <pubKeyHash 20>, OP_EQUALVERIFY, OP_CHECKSIG
        return bytes.concat(OP_DUB, OP_HASH160, PUSH_20, pHash, OP_EQUALVERIFY, OP_CHECKSIG);
    }

    /// @notice Get the associated script out for a P2SH address
    function scriptP2SH(
        bytes20 sHash
    ) internal pure returns (bytes memory) {
        // OP_HASH160, <data 20>, OP_EQUAL
        return bytes.concat(OP_HASH160, PUSH_20, sHash, OP_EQUAL);
    }

    function scriptP2WPKH(
        bytes20 witnessProgram
    ) internal pure returns (bytes memory) {
        // OP_0, <data 20>
        return bytes.concat(OP_0, PUSH_20, witnessProgram);
    }

    function scriptP2WSH(
        bytes32 witnessProgram
    ) internal pure returns (bytes memory) {
        return bytes.concat(OP_0, PUSH_32, witnessProgram);
    }

    function scriptP2TR(
        bytes32 witnessProgram
    ) internal pure returns (bytes memory) {
        return bytes.concat(OP_1, PUSH_32, witnessProgram);
    }

    /**
     * @notice Creates the expected OP_RETURN script to embed data onto the Bitcoin blockchain.
     * @dev Maximum script length is type(uint32).max. Empty script returns [OP_RETURN, OP_0].
     */
    function embedOpReturn(
        bytes calldata returnScript
    ) internal pure returns (bytes memory) {
        uint256 scriptLength = returnScript.length;
        // If the script length is 0, there is no valid script that describes that.
        // The closest approximation is:
        if (scriptLength == 0) return bytes.concat(OP_RETURN, OP_0);
        // Pushing between 1 and 75 bytes is done with their respective opcode
        // which helpfully is the opcodes 0x01 to 0x4b (75)
        if (scriptLength <= 75) return bytes.concat(OP_RETURN, bytes1(uint8(scriptLength)), returnScript);
        // If script length is more than than 75, we need to use the longer push codes.
        // The first one 0x4c allows us to specify with 1 byte how many bytes to push:
        if (scriptLength <= type(uint8).max) {
            return bytes.concat(OP_RETURN, OP_PUSHDATA1, bytes1(uint8(scriptLength)), returnScript);
        }
        // The next 0x4d allows us to specify with 2 bytes
        if (scriptLength <= type(uint16).max) {
            return bytes.concat(OP_RETURN, OP_PUSHDATA2, bytes2(uint16(scriptLength)), returnScript);
        }
        // The next 0x4e allows us to specify with 4 bytes
        if (scriptLength <= type(uint32).max) {
            return bytes.concat(OP_RETURN, OP_PUSHDATA4, bytes4(uint32(scriptLength)), returnScript);
        }

        // We can't add all script data.
        revert ScriptTooLong(scriptLength);
    }
}
