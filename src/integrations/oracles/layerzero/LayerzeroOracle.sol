/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../oracles/ChainMap.sol";
import { MessagingFee, MinimalOApp, Origin } from "./external/layerzero-v2/MinimalOApp.sol";

/**
 * @notice Layerzero Oracle.
 * Implements a transparent oracle that allows both sending and receiving messages using LayerZero protocol along with
 * exposing the hash of received messages.
 */
contract LayerzeroOracle is ChainMap, BaseInputOracle, MinimalOApp {
    using LibAddress for address;

    error NotAllPayloadsValid();

    /**
     * @notice Initialize with Endpoint V2 and owner address
     * @param _endpoint The local chain's LayerZero Endpoint V2 address
     * @param _owner    The address permitted to configure the oracle chain mapping
     */
    constructor(address _endpoint, address _owner) MinimalOApp(_endpoint) ChainMap(_owner) { }

    /**
     * @notice Returns the estimated messaging fee for sending a message
     * @param dstEid The destination endpoint ID
     * @param recipientOracle The address of the recipient oracle
     * @param source The address of the source oracle
     * @param payloads The payloads to be submitted
     * @param options Message execution options (gas limit, etc.)
     * @param payInLzToken Whether to pay the fee in LZ tokens
     * @return fee The estimated MessagingFee (nativeFee and lzTokenFee)
     */
    function quote(
        uint32 dstEid,
        address recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes calldata options,
        bool payInLzToken
    ) public view returns (MessagingFee memory fee) {
        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);
        return _quote(dstEid, recipientOracle, message, options, payInLzToken);
    }

    /**
     * @notice Submit a message to the LayerZero Endpoint V2
     * @param dstEid The destination endpoint ID
     * @param recipientOracle The address of the recipient oracle
     * @param source The address of the source oracle
     * @param payloads The payloads to be submitted
     * @param options Message execution options (gas limit, etc.)
     */
    function submit(
        uint32 dstEid,
        address recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes calldata options
    ) public payable {
        _submit(dstEid, recipientOracle, source, payloads, options);
    }

    /**
     * @notice Submit a message to the LayerZero Endpoint V2
     * @param dstEid The destination endpoint ID
     * @param recipientOracle The address of the recipient oracle
     * @param source The address of the source oracle
     * @param payloads The payloads to be submitted
     * @param options Message execution options (gas limit, etc.)
     */
    function _submit(
        uint32 dstEid,
        address recipientOracle,
        address source,
        bytes[] calldata payloads,
        bytes calldata options
    ) internal {
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();

        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);

        _lzSend(dstEid, recipientOracle, message, options, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32, /*_guid*/
        bytes calldata message,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    ) internal override {
        (bytes32 application, bytes32[] memory payloadHashes) = MessageEncodingLib.getHashesOfEncodedPayloads(message);

        uint256 remoteChainId = _getMappedChainId(uint256(_origin.srcEid));

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i; i < numPayloads; ++i) {
            bytes32 payloadHash = payloadHashes[i];
            _attestations[remoteChainId][_origin.sender][application][payloadHash] = true;

            emit OutputProven(remoteChainId, _origin.sender, application, payloadHash);
        }
    }
}
