/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../oracles/ChainMap.sol";
import { MessagingFee, MinimalOApp, Origin } from "./external/layerzero-v2/MinimalOApp.sol";
import { SetConfigParam } from "./external/layerzero-v2/interfaces/IMessageLibManager.sol";

/**
 * @notice Layerzero Oracle.
 * Implements a transparent oracle that allows both sending and receiving messages using LayerZero protocol along with
 * exposing the hash of received messages.
 */
contract LayerzeroOracle is ChainMap, BaseInputOracle, MinimalOApp {
    using LibAddress for address;

    error NotAllPayloadsValid();

    /**
     * @notice Initialize with Endpoint V2, owner address, and optional configurations
     * @param _endpoint The local chain's LayerZero Endpoint V2 address
     * @param _owner The address permitted to configure the oracle chain mapping
     * @param _sendLibrary The send library address to configure (if configuring send)
     * @param _receiveLibrary The receive library address to configure (if configuring receive)
     * @param _sendConfig Send configuration params (ULN + Executor config). Pass empty array to use defaults.
     * @param _receiveConfig Receive configuration params (ULN config only). Pass empty array to use defaults.
     */
    constructor(
        address _endpoint,
        address _owner,
        address _sendLibrary,
        address _receiveLibrary,
        SetConfigParam[] memory _sendConfig,
        SetConfigParam[] memory _receiveConfig
    ) MinimalOApp(_endpoint) ChainMap(_owner) {
        // Set send configuration (ULN + Executor) if provided
        if (_sendConfig.length > 0) {
            endpoint.setConfig(address(this), _sendLibrary, _sendConfig);
        }

        // Set receive configuration (ULN only) if provided
        if (_receiveConfig.length > 0) {
            endpoint.setConfig(address(this), _receiveLibrary, _receiveConfig);
        }
    }

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

    /**
     * @notice Get the configuration for a specific library, endpoint, and config type
     * @param _lib The message library address
     * @param _eid The endpoint ID
     * @param _configType The config type (1 = Executor, 2 = ULN/DVN)
     * @return config The configuration bytes (needs to be decoded based on configType)
     */
    function getConfig(address _lib, uint32 _eid, uint32 _configType) external view returns (bytes memory config) {
        return endpoint.getConfig(address(this), _lib, _eid, _configType);
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
