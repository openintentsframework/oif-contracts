// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { OutputSettlerSimple } from "../../../src/output/simple/OutputSettlerSimple.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

import { LayerzeroOracle } from "../../../src/integrations/oracles/layerzero/LayerzeroOracle.sol";
import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin
} from "../../../src/integrations/oracles/layerzero/external/layerzero-v2/interfaces/ILayerZeroEndpointV2.sol";
import {
    SetConfigParam
} from "../../../src/integrations/oracles/layerzero/external/layerzero-v2/interfaces/IMessageLibManager.sol";

event OutputProven(uint256 chainid, bytes32 remoteIdentifier, bytes32 application, bytes32 payloadHash);

/**
 * @notice Mock LayerZero Endpoint V2 for testing
 */
contract LayerZeroEndpointV2Mock {
    uint64 public nonce;
    address public lzToken;

    // Store configs: oapp => lib => eid => configType => config
    mapping(address => mapping(address => mapping(uint32 => mapping(uint32 => bytes)))) private configs;

    function quote(
        MessagingParams calldata,
        address
    ) external pure returns (MessagingFee memory fee) {
        return MessagingFee({ nativeFee: 0.5 ether, lzTokenFee: 0 });
    }

    function send(
        MessagingParams calldata params,
        address refundAddress
    ) external payable returns (MessagingReceipt memory receipt) {
        nonce += 1;

        // Simulate refund of excess fees
        uint256 actualFee = 0.5 ether;
        if (msg.value > actualFee) {
            uint256 refund = msg.value - actualFee;
            (bool success,) = refundAddress.call{ value: refund }("");
            require(success, "Refund failed");
        }

        return MessagingReceipt({
            guid: keccak256(abi.encode(params, nonce)),
            nonce: nonce,
            fee: MessagingFee({ nativeFee: actualFee, lzTokenFee: 0 })
        });
    }

    function setLzToken(
        address _lzToken
    ) external {
        lzToken = _lzToken;
    }

    function setConfig(
        address _oapp,
        address _lib,
        SetConfigParam[] calldata _params
    ) external {
        for (uint256 i = 0; i < _params.length; i++) {
            configs[_oapp][_lib][_params[i].eid][_params[i].configType] = _params[i].config;
        }
    }

    function getConfig(
        address _oapp,
        address _lib,
        uint32 _eid,
        uint32 _configType
    ) external view returns (bytes memory) {
        return configs[_oapp][_lib][_eid][_configType];
    }
}

contract LayerzeroOracleTest is Test {
    using LibAddress for address;

    LayerZeroEndpointV2Mock internal _endpoint;
    LayerzeroOracle internal _oracle;

    OutputSettlerSimple internal _outputSettler;
    MockERC20 internal _token;

    uint32 internal _dstEid = 40_161; // Ethereum mainnet endpoint ID
    uint32 internal _srcEid = 40_245; // Arbitrum mainnet endpoint ID
    address internal _recipientOracle = makeAddr("recipientOracle");
    address internal _owner = makeAddr("owner");

    function setUp() public {
        _outputSettler = new OutputSettlerSimple();
        _token = new MockERC20("TEST", "TEST", 18);

        _endpoint = new LayerZeroEndpointV2Mock();

        // Create empty config arrays to use LayerZero defaults
        SetConfigParam[] memory emptySendConfig = new SetConfigParam[](0);
        SetConfigParam[] memory emptyReceiveConfig = new SetConfigParam[](0);

        _oracle = new LayerzeroOracle(
            address(_endpoint),
            _owner,
            address(0), // sendLibrary (not needed for default config)
            address(0), // receiveLibrary (not needed for default config)
            emptySendConfig,
            emptyReceiveConfig
        );

        // Set up chain mapping: srcEid -> chainId
        vm.prank(_owner);
        _oracle.setChainMap(_srcEid, 42_161); // Arbitrum chainId
    }

    function _getMandatePayload(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) internal returns (MandateOutput memory output, bytes memory payload) {
        _token.mint(sender, amount);
        vm.prank(sender);
        _token.approve(address(_outputSettler), amount);

        output = MandateOutput({
            oracle: address(_oracle).toIdentifier(),
            settler: address(_outputSettler).toIdentifier(),
            chainId: block.chainid,
            token: bytes32(abi.encode(address(_token))),
            amount: amount,
            recipient: bytes32(abi.encode(recipient)),
            callbackData: bytes(""),
            context: bytes("")
        });

        payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solverIdentifier,
            orderId,
            uint32(block.timestamp),
            bytes32(abi.encode(address(_token))),
            amount,
            bytes32(abi.encode(recipient)),
            bytes(""),
            bytes("")
        );

        return (output, payload);
    }

    function encodeMessageCalldata(
        bytes32 identifier,
        bytes[] calldata payloads
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(identifier, payloads);
    }

    function getHashesOfEncodedPayloads(
        bytes calldata encodedMessage
    ) external pure returns (bytes32 application, bytes32[] memory payloadHashes) {
        (application, payloadHashes) = MessageEncodingLib.getHashesOfEncodedPayloads(encodedMessage);
    }

    // --- ChainMap Tests --- //

    function test_setChainMap_works() external {
        uint32 protocolEid = 40_106; // Avalanche endpoint ID
        uint256 chainId = 43_114; // Avalanche chainId

        vm.prank(_owner);
        _oracle.setChainMap(protocolEid, chainId);

        assertEq(_oracle.chainIdMap(protocolEid), chainId);
        assertEq(_oracle.reverseChainIdMap(chainId), protocolEid);
    }

    function test_setChainMap_onlyOwner() external {
        uint32 protocolEid = 40_106;
        uint256 chainId = 43_114;

        vm.expectRevert();
        _oracle.setChainMap(protocolEid, chainId);
    }

    function test_setChainMap_alreadySet() external {
        uint32 protocolEid = 40_106;
        uint256 chainId = 43_114;

        vm.startPrank(_owner);
        _oracle.setChainMap(protocolEid, chainId);

        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        _oracle.setChainMap(protocolEid, chainId);
        vm.stopPrank();
    }

    // --- Quote Tests --- //

    function test_quote_works() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = bytes("test payload");

        bytes memory options = hex"0003010011010000000000000000000000000000ea60"; // Example options

        MessagingFee memory fee =
            _oracle.quote(_dstEid, _recipientOracle, address(_outputSettler), payloads, options, false);

        assertEq(fee.nativeFee, 0.5 ether);
        assertEq(fee.lzTokenFee, 0);
    }

    // --- Submit Tests --- //

    function test_submit_notAllPayloadsValid() external {
        address sender = makeAddr("sender");
        uint256 amount = 1 ether;
        address recipient = makeAddr("recipient");
        bytes32 orderId = keccak256(bytes("orderId"));
        bytes32 solverIdentifier = keccak256(bytes("solverIdentifier"));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        bytes memory options = hex"0003010011010000000000000000000000000000ea60";

        // Try to submit without filling (payloads not attested)
        vm.expectRevert(abi.encodeWithSignature("NotAllPayloadsValid()"));
        _oracle.submit{ value: 1 ether }(_dstEid, _recipientOracle, address(_outputSettler), payloads, options);
    }

    function test_submit_works() external {
        address sender = makeAddr("sender");
        uint256 amount = 1 ether;
        address recipient = makeAddr("recipient");
        bytes32 orderId = keccak256(bytes("orderId"));
        bytes32 solverIdentifier = keccak256(bytes("solverIdentifier"));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        // Fill the output to attest the payload
        bytes memory fillerData = abi.encodePacked(solverIdentifier);
        vm.prank(sender);
        _outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        bytes memory options = hex"0003010011010000000000000000000000000000ea60";

        // Submit should succeed
        vm.expectCall(address(_endpoint), abi.encodeWithSelector(LayerZeroEndpointV2Mock.send.selector));

        _oracle.submit{ value: 1 ether }(_dstEid, _recipientOracle, address(_outputSettler), payloads, options);
        vm.snapshotGasLastCall("oracle", "layerzeroOracleSubmit");
    }

    function test_submit_refundsExcess() external {
        address sender = makeAddr("sender");
        uint256 amount = 1 ether;
        address recipient = makeAddr("recipient");
        bytes32 orderId = keccak256(bytes("orderId"));
        bytes32 solverIdentifier = keccak256(bytes("solverIdentifier"));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        // Fill the output
        bytes memory fillerData = abi.encodePacked(solverIdentifier);
        vm.prank(sender);
        _outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        bytes memory options = hex"0003010011010000000000000000000000000000ea60";

        // Send more than needed (actual fee is 0.5 ether)
        uint256 balanceBefore = address(this).balance;
        _oracle.submit{ value: 2 ether }(_dstEid, _recipientOracle, address(_outputSettler), payloads, options);
        uint256 balanceAfter = address(this).balance;

        assertEq(balanceBefore - balanceAfter, 0.5 ether);
    }

    // --- lzReceive Tests --- //

    function test_lzReceive_onlyEndpoint() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = bytes("test payload");

        bytes memory message = this.encodeMessageCalldata(address(_outputSettler).toIdentifier(), payloads);

        Origin memory origin = Origin({ srcEid: _srcEid, sender: _recipientOracle.toIdentifier(), nonce: 1 });

        // Should revert if not called by endpoint
        vm.expectRevert();
        _oracle.lzReceive(origin, bytes32(0), message, address(0), bytes(""));
    }

    function test_lzReceive_works() external {
        address sender = makeAddr("sender");
        uint256 amount = 1 ether;
        address recipient = makeAddr("recipient");
        bytes32 orderId = keccak256(bytes("orderId"));
        bytes32 solverIdentifier = keccak256(bytes("solverIdentifier"));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        bytes memory message = this.encodeMessageCalldata(address(_outputSettler).toIdentifier(), payloads);
        (bytes32 application, bytes32[] memory payloadHashes) = this.getHashesOfEncodedPayloads(message);

        bytes32 remoteSender = makeAddr("remoteSender").toIdentifier();
        Origin memory origin = Origin({ srcEid: _srcEid, sender: remoteSender, nonce: 1 });

        // Expect event emission with mapped chain ID
        vm.expectEmit();
        emit OutputProven(42_161, remoteSender, application, payloadHashes[0]);

        // Call lzReceive as endpoint
        vm.prank(address(_endpoint));
        _oracle.lzReceive(origin, bytes32(0), message, address(0), bytes(""));
        vm.snapshotGasLastCall("oracle", "layerzeroOracleLzReceive");

        // Verify attestation is stored with mapped chain ID
        assertTrue(_oracle.isProven(42_161, remoteSender, application, payloadHashes[0]));
    }

    function test_lzReceive_multiplePayloads() external {
        bytes[] memory payloads = new bytes[](3);
        payloads[0] = bytes("payload 1");
        payloads[1] = bytes("payload 2");
        payloads[2] = bytes("payload 3");

        bytes memory message = this.encodeMessageCalldata(address(_outputSettler).toIdentifier(), payloads);
        (bytes32 application, bytes32[] memory payloadHashes) = this.getHashesOfEncodedPayloads(message);

        bytes32 remoteSender = makeAddr("remoteSender").toIdentifier();
        Origin memory origin = Origin({ srcEid: _srcEid, sender: remoteSender, nonce: 1 });

        // Call lzReceive as endpoint
        vm.prank(address(_endpoint));
        _oracle.lzReceive(origin, bytes32(0), message, address(0), bytes(""));

        // Verify all payloads are attested
        for (uint256 i = 0; i < payloadHashes.length; i++) {
            assertTrue(_oracle.isProven(42_161, remoteSender, application, payloadHashes[i]));
        }
    }

    // --- Configuration Tests --- //

    function test_constructor_withCustomConfig() external {
        address sendLibrary = makeAddr("sendLibrary");
        address receiveLibrary = makeAddr("receiveLibrary");

        // Create custom configs
        SetConfigParam[] memory customSendConfig = new SetConfigParam[](1);
        customSendConfig[0] = SetConfigParam({
            eid: _dstEid,
            configType: 2, // ULN/DVN config
            config: abi.encode(uint64(15), uint8(2), uint8(1), uint8(0), new address[](2), new address[](0))
        });

        SetConfigParam[] memory customReceiveConfig = new SetConfigParam[](1);
        customReceiveConfig[0] = SetConfigParam({
            eid: _srcEid,
            configType: 2, // ULN/DVN config
            config: abi.encode(uint64(20), uint8(2), uint8(1), uint8(0), new address[](2), new address[](0))
        });

        // Deploy oracle with custom configs
        LayerzeroOracle oracleWithConfig = new LayerzeroOracle(
            address(_endpoint), _owner, sendLibrary, receiveLibrary, customSendConfig, customReceiveConfig
        );

        // Verify the oracle was created successfully
        assertEq(address(oracleWithConfig.endpoint()), address(_endpoint));
    }

    function test_getConfig_works() external {
        address sendLibrary = makeAddr("sendLibrary");
        uint32 eid = _dstEid;
        uint32 configType = 2; // ULN/DVN config

        // Create and set a config
        SetConfigParam[] memory customSendConfig = new SetConfigParam[](1);
        bytes memory configData =
            abi.encode(uint64(15), uint8(2), uint8(1), uint8(0), new address[](2), new address[](0));
        customSendConfig[0] = SetConfigParam({ eid: eid, configType: configType, config: configData });

        LayerzeroOracle oracleWithConfig = new LayerzeroOracle(
            address(_endpoint), _owner, sendLibrary, address(0), customSendConfig, new SetConfigParam[](0)
        );

        // Retrieve the config
        bytes memory retrievedConfig = oracleWithConfig.getConfig(sendLibrary, eid, configType);

        // Verify config was stored correctly
        assertEq(keccak256(retrievedConfig), keccak256(configData));
    }

    receive() external payable { }
}
