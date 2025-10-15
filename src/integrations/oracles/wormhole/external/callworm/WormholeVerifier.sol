// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "../wormhole/Structs.sol";
import "../wormhole/libraries/external/BytesLib.sol";
import "./GettersGetter.sol";

/**
 * @notice Optimised message verifier for Wormhole
 * @dev Is based on the Wormhole verification library.
 */
contract WormholeVerifier is GettersGetter {
    using BytesLib for bytes;

    error InvalidSignatory();
    error SignatureIndicesNotAscending();
    error GuardianIndexOutOfBounds();
    error VMVersionIncompatible();
    error TooManyGuardians();
    error VMSignatureInvalid();
    error InvalidGuardianSet();
    error GuardianSetExpired();
    error NoQuorum();

    constructor(
        address wormholeState
    ) payable GettersGetter(wormholeState) { }

    /// @dev parseAndVerifyVM serves to parse an encodedVM and wholly validate it for consumption
    function parseAndVerifyVM(
        bytes calldata encodedVM
    ) public view returns (uint16 emitterChainId, bytes32 emitterAddress, bytes calldata payload) {
        bytes calldata signatures;
        bytes32 bodyHash;
        uint32 guardianSetIndex;
        (emitterChainId, emitterAddress, guardianSetIndex, signatures, bodyHash, payload) = parseVM(encodedVM);
        /// setting checkHash to false as we can trust the hash field in this case given that parseVM computes and then
        /// sets the hash field above
        verifyVMInternal(guardianSetIndex, signatures, bodyHash);
    }

    /**
     * @dev `verifyVMInternal` serves to validate an arbitrary vm against a valid Guardian set
     * if checkHash is set then the hash field of the vm is verified against the hash of its contents
     * in the case that the vm is securely parsed and the hash field can be trusted, checkHash can be set to false
     * as the check would be redundant
     */
    function verifyVMInternal(
        uint32 guardianSetIndex,
        bytes calldata signatures,
        bytes32 bodyHash
    ) internal view {
        /// @dev Obtain the current guardianSet for the guardianSetIndex provided
        Structs.GuardianSet memory guardianSet = getGuardianSet(guardianSetIndex);

        /**
         * @dev Checks whether the guardianSet has zero keys
         * WARNING: This keys check is critical to ensure the guardianSet has keys present AND to ensure
         * that guardianSet key size doesn't fall to zero and negatively impact quorum assessment.  If guardianSet
         * key length is 0 and vm.signatures length is 0, this could compromise the integrity of both vm and
         * signature verification.
         */
        if (guardianSet.keys.length == 0) revert InvalidGuardianSet();

        /// @dev Checks if VM guardian set index matches the current index (unless the current set is expired).
        if (guardianSet.expirationTime < block.timestamp) {
            if (guardianSetIndex != getCurrentGuardianSetIndex()) revert GuardianSetExpired();
        }

        /**
         * @dev We're using a fixed point number transformation with 1 decimal to deal with rounding.
         *   WARNING: This quorum check is critical to assessing whether we have enough Guardian signatures to validate
         * a VM
         *   if making any changes to this, obtain additional peer review. If guardianSet key length is 0 and
         *   vm.signatures length is 0, this could compromise the integrity of both vm and signature verification.
         */
        if (uint8(signatures[0]) < quorum(guardianSet.keys.length)) revert NoQuorum();

        /// @dev Verify the proposed vm.signatures against the guardianSet
        verifySignatures(bodyHash, signatures, guardianSet);

        /// If we are here, we've validated the VM is a valid multi-sig that matches the guardianSet.
    }

    /**
     * @dev verifySignatures serves to validate arbitrary signatures against an arbitrary guardianSet
     *  - it intentionally does not solve for expectations within guardianSet (you should use verifyVM if you need these
     * protections)
     *  - it intentioanlly does not solve for quorum (you should use verifyVM if you need these protections)
     *  - it intentionally returns true when signatures is an empty set (you should use verifyVM if you need these
     * protections)
     */
    function verifySignatures(
        bytes32 hash,
        bytes calldata signatures,
        Structs.GuardianSet memory guardianSet
    ) public pure {
        uint8 lastIndex = 0;
        uint256 guardianCount = guardianSet.keys.length;
        uint256 signersLen = uint8(bytes1(signatures[0]));
        uint256 index = 1;
        unchecked {
            for (uint256 i = 0; i < signersLen; ++i) {
                uint8 guardianIndex = uint8(bytes1(signatures[index]));
                index += 1;

                bytes32 r;
                bytes32 s;
                bytes1 v1;
                assembly {
                    // Load r, s via assembly to save gas.
                    // bytes32 r = bytes32(signatures[index: index + 32]);
                    r := calldataload(add(signatures.offset, index))
                    index := add(index, 0x20) // index += 32;
                        // bytes32 s = bytes32(signatures[index: index + 32]);
                    s := calldataload(add(signatures.offset, index))
                    index := add(index, 0x20) // index += 32;
                        // bytes1(signatures[index:index + 1])
                    v1 := calldataload(add(signatures.offset, index))
                    index := add(index, 0x01) // index += 1;
                }
                uint8 v = uint8(v1) + 27;
                address signatory = ecrecover(hash, v, r, s);
                // ecrecover returns 0 for invalid signatures. We explicitly require valid signatures to avoid
                // unexpected
                // behaviour due to the default storage slot value also being 0.
                if (signatory == address(0)) revert InvalidSignatory();

                /// Ensure that provided signature indices are ascending only
                if (!(i == 0 || guardianIndex > lastIndex)) revert SignatureIndicesNotAscending();
                lastIndex = guardianIndex;

                /// @dev Ensure that the provided signature index is within the
                /// bounds of the guardianSet. This is implicitly checked by the array
                /// index operation below, so this check is technically redundant.
                /// However, reverting explicitly here ensures that a bug is not
                /// introduced accidentally later due to the nontrivial storage
                /// semantics of solidity.
                if (guardianIndex >= guardianCount) revert GuardianIndexOutOfBounds();

                /// Check to see if the signer of the signature does not match a specific Guardian key at the provided
                /// index
                if (signatory != guardianSet.keys[guardianIndex]) revert VMSignatureInvalid();
            }

            /// If we are here, we've validated that the provided signatures are valid for the provided guardianSet
        }
    }

    /**
     * @dev parseVM serves to parse an encodedVM into a vm struct
     *  - it intentionally performs no validation functions, it simply parses raw into a struct
     */
    function parseVM(
        bytes calldata encodedVM
    )
        public
        view
        virtual
        returns (
            uint16 emitterChainId,
            bytes32 emitterAddress,
            uint32 guardianSetIndex,
            bytes calldata signatures,
            bytes32 bodyHash,
            bytes calldata payload
        )
    {
        unchecked {
            uint256 index = 0;

            uint8 version = uint8(bytes1(encodedVM[0:1]));

            index += 1;

            // SECURITY: Note that currently the VM.version is not part of the hash
            // and for reasons described below it cannot be made part of the hash.
            // This means that this field's integrity is not protected and cannot be trusted.
            // This is not a problem today since there is only one accepted version, but it
            // could be a problem if we wanted to allow other versions in the future.
            if (version != 1) revert VMVersionIncompatible();

            guardianSetIndex = uint32(bytes4(encodedVM[1:4 + 1]));
            index += 4;

            // Parse Signatures
            uint256 signersLen = uint8(bytes1(encodedVM[5:5 + 1]));
            signatures = encodedVM[5:5 + 1 + signersLen * (1 + 32 + 32 + 1)];
            index += 1 + signersLen * (1 + 32 + 32 + 1);
            // signatures = new Structs.Signature[](signersLen);
            // for (uint i = 0; i < signersLen; ++i) {
            //     signatures[i].guardianIndex = uint8(bytes1(encodedVM[index:index+1]));
            //     index += 1;

            //     signatures[i].r = bytes32(encodedVM[index:index+32]);
            //     index += 32;
            //     signatures[i].s = bytes32(encodedVM[index:index+32]);
            //     index += 32;
            //     signatures[i].v = uint8(bytes1(encodedVM[index:index+1])) + 27;
            //     index += 1;
            // }

            /*
            Hash the body

            SECURITY: Do not change the way the hash of a VM is computed!
            Changing it could result into two different hashes for the same observation.
            But xDapps rely on the hash of an observation for replay protection.
            */
            bytes calldata body = encodedVM[index:];
            bodyHash = keccak256(abi.encodePacked(keccak256(body)));

            // Parse the body
            // vm.timestamp = uint32(bytes4(encodedVM[index:index+4]));
            // index += 4;

            // vm.nonce = uint32(bytes4(encodedVM[index:index+4]));
            // index += 4;
            index += 8;

            emitterChainId = uint16(bytes2(encodedVM[index:index += 2]));

            assembly ("memory-safe") {
                // emitterAddress = bytes32(encodedVM[index:index+32]);
                emitterAddress := calldataload(add(encodedVM.offset, index))
            }
            // index += 32;

            // vm.sequence = uint64(bytes8(encodedVM[index:index+8]));
            // index += 8;

            // vm.consistencyLevel = uint8(bytes1(encodedVM[index:index+1]));
            // index += 1;

            index += 32 + 8 + 1;
            payload = encodedVM[index:];
        }
    }

    /**
     * @dev quorum serves solely to determine the number of signatures required to achieve quorum
     */
    function quorum(
        uint256 numGuardians
    ) public pure virtual returns (uint256 numSignaturesRequiredForQuorum) {
        unchecked {
            // The max number of guardians is 255
            if (numGuardians >= 256) revert TooManyGuardians();
            return ((numGuardians * 2) / 3) + 1;
        }
    }
}
