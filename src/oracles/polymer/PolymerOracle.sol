// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "../../libs/LibAddress.sol";
import { LibBytes } from "solady/utils/LibBytes.sol";

import { MandateOutput, MandateOutputEncodingLib } from "../../libs/MandateOutputEncodingLib.sol";

import { BaseOracle } from "../BaseOracle.sol";
import { ICrossL2Prover } from "./ICrossL2Prover.sol";

/**
 * @notice Polymer Oracle.
 * Polymer uses the fill event to reconstruct the payload for verification instead of sending messages cross-chain.
 */
contract PolymerOracle is BaseOracle {
    using LibAddress for address;

    ICrossL2Prover CROSS_L2_PROVER;

    constructor(
        address crossL2Prover
    ) {
        CROSS_L2_PROVER = ICrossL2Prover(crossL2Prover);
    }

    function _getChainId(
        uint256 protocolId
    ) internal view virtual returns (uint256 chainId) {
        return protocolId;
    }

    function _proofPayloadHash(
        bytes32 orderId,
        bytes32 solver,
        uint32 timestamp,
        MandateOutput memory mandateOutput
    ) internal pure returns (bytes32 outputHash) {
        return outputHash =
            keccak256(MandateOutputEncodingLib.encodeFillDescriptionM(solver, orderId, timestamp, mandateOutput));
    }

    function _processMessage(
        bytes calldata proof
    ) internal {
        (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData) =
            CROSS_L2_PROVER.validateEvent(proof);

        // OrderId is topic[1] which is 32 to 64 bytes.
        bytes32 orderId = bytes32(LibBytes.slice(topics, 32, 64));

        (bytes32 solver, uint32 timestamp, MandateOutput memory output) =
            abi.decode(unindexedData, (bytes32, uint32, MandateOutput));

        bytes32 payloadHash = _proofPayloadHash(orderId, solver, timestamp, output);

        // Convert the Polymer ChainID into the canonical chainId.
        uint256 remoteChainId = _getChainId(uint256(chainId));

        bytes32 application = emittingContract.toIdentifier();
        _attestations[remoteChainId][address(this).toIdentifier()][application][payloadHash] = true;

        emit OutputProven(remoteChainId, address(this).toIdentifier(), application, payloadHash);
    }

    function receiveMessage(
        bytes calldata proof
    ) external {
        _processMessage(proof);
    }

    function receiveMessage(
        bytes[] calldata proofs
    ) external {
        uint256 numProofs = proofs.length;
        for (uint256 i; i < numProofs; ++i) {
            _processMessage(proofs[i]);
        }
    }
}
