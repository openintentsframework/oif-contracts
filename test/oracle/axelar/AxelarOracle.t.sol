// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "src/input/types/MandateOutputType.sol";

import { AxelarOracle } from "src/integrations/oracles/axelar/AxelarOracle.sol";

import { IAxelarExecutable } from "src/integrations/oracles/axelar/external/axelar/interfaces/IAxelarExecutable.sol";
import { IAxelarGasService } from "src/integrations/oracles/axelar/external/axelar/interfaces/IAxelarGasService.sol";
import { AddressToString } from "src/integrations/oracles/axelar/external/axelar/libs/AddressString.sol";
import { MockAxelarGasService } from "src/integrations/oracles/axelar/external/axelar/mocks/MockAxelarGasService.sol";
import { MockAxelarGateway } from "src/integrations/oracles/axelar/external/axelar/mocks/MockAxelarGateway.sol";

import { LibAddress } from "src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "src/libs/MessageEncodingLib.sol";

import { BaseInputOracle } from "src/oracles/BaseInputOracle.sol";
import { OutputSettlerSimple } from "src/output/simple/OutputSettlerSimple.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

contract AxelarOracleTest is Test {
    using LibAddress for address;
    using AddressToString for address;

    MockAxelarGateway internal _axelarGateway;
    MockAxelarGasService internal _axelarGasService;
    AxelarOracle internal _oracle;

    OutputSettlerSimple _outputSettler;
    MockERC20 _token;

    string internal _origin = "ethereum-sepolia";
    uint256 internal _originChainId = 1;
    string internal _destination = "arbitrum-sepolia";
    uint256 internal _destinationChainId = 2;
    address internal _recipientOracle = makeAddr("axi");
    uint256 internal _gasPayment = 1e18;
    bytes32 internal _commandId = keccak256(bytes("commandId"));

    function setUp() public {
        _outputSettler = new OutputSettlerSimple();
        _token = new MockERC20("TEST", "TEST", 18);

        _axelarGateway = new MockAxelarGateway();
        _axelarGasService = new MockAxelarGasService();
        _oracle = new AxelarOracle(address(_axelarGateway), address(_axelarGasService), address(this));
        _oracle.setChainMap(uint256(keccak256(abi.encodePacked(_origin))), _originChainId);
        _oracle.setChainMap(uint256(keccak256(abi.encodePacked(_destination))), _destinationChainId);
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

    function test_invalid_gas_service() public {
        vm.expectRevert(IAxelarGasService.InvalidAddress.selector);
        new AxelarOracle(address(_axelarGateway), address(0), address(this));
    }

    function test_submit_NotAllPayloadsValid(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) public {
        vm.assume(solverIdentifier != bytes32(0) && sender != address(0) && recipient != address(0));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        vm.expectRevert(AxelarOracle.NotAllPayloadsValid.selector);
        _oracle.submit{
            value: _gasPayment
        }(_destination, _recipientOracle.toString(), address(_outputSettler), payloads);
    }

    function test_submit_InvalidSourceAddress() public {
        address sender = makeAddr("sender");
        uint256 amount = 10 ** 18;
        address recipient = makeAddr("recipient");
        bytes32 orderId = keccak256(bytes("orderId"));
        bytes32 solverIdentifier = keccak256(bytes("solverIdentifier"));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        vm.expectCall(
            address(_token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(sender), recipient, amount)
        );

        bytes memory fillerData = abi.encodePacked(solverIdentifier);

        vm.prank(sender);
        _outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        vm.expectRevert(IAxelarGasService.InvalidAddress.selector);
        _oracle.submit{ value: _gasPayment }(_destination, _recipientOracle.toString(), address(0), payloads);
    }

    function test_submit_EmptyPayloadsNotAllowed() public {
        address sender = makeAddr("sender");
        uint256 amount = 10 ** 18;
        address recipient = makeAddr("recipient");
        bytes32 orderId = keccak256(bytes("orderId"));
        bytes32 solverIdentifier = keccak256(bytes("solverIdentifier"));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](0);
        (output,) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        vm.expectCall(
            address(_token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(sender), recipient, amount)
        );

        bytes memory fillerData = abi.encodePacked(solverIdentifier);

        vm.prank(sender);
        _outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        vm.expectRevert(AxelarOracle.EmptyPayloadsNotAllowed.selector);
        _oracle.submit{
            value: _gasPayment
        }(_destination, _recipientOracle.toString(), address(_outputSettler), payloads);
    }

    function test_submit_works_w() external {
        test_submit_works(
            makeAddr("sender"),
            10 ** 18,
            makeAddr("recipient"),
            keccak256(bytes("orderId")),
            keccak256(bytes("solverIdentifier"))
        );
    }

    function test_submit_works(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) public {
        vm.assume(solverIdentifier != bytes32(0) && sender != address(0) && recipient != address(0));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        vm.expectCall(
            address(_token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(sender), recipient, amount)
        );

        bytes memory fillerData = abi.encodePacked(solverIdentifier);

        vm.prank(sender);
        _outputSettler.fill(orderId, output, type(uint48).max, fillerData);

        vm.expectCall(
            address(_axelarGateway),
            abi.encodeWithSelector(
                MockAxelarGateway.callContract.selector,
                _destination,
                _recipientOracle.toString(),
                this.encodeMessageCalldata(address(_outputSettler).toIdentifier(), payloads)
            )
        );

        _oracle.submit{
            value: _gasPayment
        }(_destination, _recipientOracle.toString(), address(_outputSettler), payloads);
        vm.snapshotGasLastCall("oracle", "axelarOracleSubmit");
    }

    function test_handle_NotApprovedByGateway(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) public {
        vm.assume(solverIdentifier != bytes32(0) && sender != address(0) && recipient != address(0));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        bytes memory message = this.encodeMessageCalldata(address(_outputSettler).toIdentifier(), payloads);

        (bytes32 application, bytes32[] memory payloadHashes) = this.getHashesOfEncodedPayloads(message);

        address messageSender = makeAddr("messageSender");

        vm.prank(address(_axelarGateway));

        // Execute without approving the message
        vm.expectRevert(IAxelarExecutable.NotApprovedByGateway.selector);
        _oracle.execute(_commandId, _origin, messageSender.toString(), message);

        assertFalse(_oracle.isProven(_originChainId, messageSender.toIdentifier(), application, payloadHashes[0]));
    }

    function test_execute_works_w() external {
        test_execute_works(
            makeAddr("sender"),
            10 ** 18,
            makeAddr("recipient"),
            keccak256(bytes("orderId")),
            keccak256(bytes("solverIdentifier"))
        );
    }

    function test_execute_works(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) public {
        vm.assume(solverIdentifier != bytes32(0) && sender != address(0) && recipient != address(0));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        bytes memory message = this.encodeMessageCalldata(address(_outputSettler).toIdentifier(), payloads);

        (bytes32 application, bytes32[] memory payloadHashes) = this.getHashesOfEncodedPayloads(message);
        address messageSender = makeAddr("messageSender");
        bytes32 messageHash = keccak256(message);

        vm.prank(address(_axelarGateway));
        _axelarGateway.approveContractCall(_commandId, _origin, messageSender.toString(), messageHash);

        vm.expectEmit();
        emit BaseInputOracle.OutputProven(_originChainId, messageSender.toIdentifier(), application, payloadHashes[0]);

        _oracle.execute(_commandId, _origin, messageSender.toString(), message);
        vm.snapshotGasLastCall("oracle", "axelarOracleExecute");

        assertTrue(_oracle.isProven(_originChainId, messageSender.toIdentifier(), application, payloadHashes[0]));
    }

    receive() external payable { }
}
