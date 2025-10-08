/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";

import { AxelarExecutable } from "./external/axelar/executable/AxelarExecutable.sol";

import { IAxelarGasService } from "./external/axelar/interfaces/IAxelarGasService.sol";
import { StringToAddress } from "./external/axelar/libs/AddressString.sol";
import { Ownable } from "openzeppelin/access/Ownable.sol";

contract AxelarOracle is BaseInputOracle, AxelarExecutable, Ownable {
    using LibAddress for address;
    using StringToAddress for string;

    error NotAllPayloadsValid();
    error SourceChainNotAllowed(string sourceChain);
    error DestinationChainNotAllowed(string destinationChain);

    IAxelarGasService public immutable gasService;

    mapping(uint32 => bool) public allowlistedSourceChains;
    mapping(uint32 => bool) public allowlistedDestinationChains;

    constructor(address gateway_, address gasService_) AxelarExecutable(gateway_) Ownable(msg.sender) {
        gasService = IAxelarGasService(gasService_);
    }

    function _execute(
        bytes32,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload_
    ) internal override {
        bytes32 hashedSourceChain = keccak256(abi.encodePacked(sourceChain));
        uint32 sourceChainId = uint32(uint256(hashedSourceChain) >> 224);

        if (!allowlistedSourceChains[sourceChainId]) revert SourceChainNotAllowed(sourceChain);

        bytes32 sourceSender = sourceAddress.toAddress().toIdentifier();

        (bytes32 application, bytes32[] memory payloadHashes) = MessageEncodingLib.getHashesOfEncodedPayloads(payload_);

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i; i < numPayloads; ++i) {
            bytes32 payloadHash = payloadHashes[i];
            _attestations[sourceChainId][sourceSender][application][payloadHash] = true;

            emit OutputProven(sourceChainId, sourceSender, application, payloadHash);
        }
    }

    function submit(
        string calldata destinationChain,
        string calldata destinationAddress,
        address source,
        bytes[] calldata payloads
    ) public payable {
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();

        bytes32 hashedDestinationChain = keccak256(abi.encodePacked(destinationChain));
        uint32 destinationChainId = uint32(uint256(hashedDestinationChain) >> 224);

        if (!allowlistedDestinationChains[destinationChainId]) revert DestinationChainNotAllowed(destinationChain);

        bytes memory message = MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads);

        gasService.payNativeGasForContractCall{ value: msg.value }(
            address(this), destinationChain, destinationAddress, message, msg.sender
        );

        gateway().callContract(destinationChain, destinationAddress, message);
    }

    function allowlistSourceChain(string memory sourceChain, bool allowed) external onlyOwner {
        bytes32 hashedSourceChain = keccak256(abi.encodePacked(sourceChain));
        uint32 sourceChainId = uint32(uint256(hashedSourceChain) >> 224);

        if (allowed) allowlistedSourceChains[sourceChainId] = true;
        else delete allowlistedSourceChains[sourceChainId];
    }

    function allowlistDestinationChain(string memory destinationChain, bool allowed) external onlyOwner {
        bytes32 hashedDestinationChain = keccak256(abi.encodePacked(destinationChain));
        uint32 destinationChainId = uint32(uint256(hashedDestinationChain) >> 224);

        if (allowed) allowlistedDestinationChains[destinationChainId] = true;
        else delete allowlistedDestinationChains[destinationChainId];
    }
}
