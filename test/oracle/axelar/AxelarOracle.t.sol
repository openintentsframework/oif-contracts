// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";

import { AxelarOracle } from "../../../src/integrations/oracles/axelar/AxelarOracle.sol";
import { AddressToString } from "../../../src/integrations/oracles/axelar/external/axelar/libs/AddressString.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";

import { OutputSettlerSimple } from "../../../src/output/simple/OutputSettlerSimple.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

event OutputProven(uint256 chainid, bytes32 remoteIdentifier, bytes32 application, bytes32 payloadHash);

contract AxelarGatewayMock {
    uint256 public dispatchCounter;

    function callContract(string calldata, string calldata, bytes calldata) external {
        dispatchCounter += 1;
    }

    function validateContractCall(
        bytes32 commandId,
        string calldata,
        string calldata,
        bytes32
    ) external pure returns (bool) {
        if (commandId == keccak256(bytes("commandId"))) return true;

        return false;
    }
}

contract AxelarGasServiceMock {
    uint256 public dispatchCounter;

    function payNativeGasForContractCall(
        address,
        string calldata,
        string calldata,
        bytes calldata,
        address
    ) external payable {
        dispatchCounter += 1;
    }
}

contract AxelarOracleTest is Test {
    using LibAddress for address;
    using AddressToString for address;

    AxelarGatewayMock internal _axelarGateway;
    AxelarGasServiceMock internal _axelarGasService;
    AxelarOracle internal _oracle;

    OutputSettlerSimple _outputSettler;
    MockERC20 _token;

    string internal _destination = "ethereum-sepolia";
    string internal _origin = "arbitrum-sepolia";
    address internal _recipientOracle = makeAddr("axi");
    uint256 internal _gasPayment = 1e18;
    bytes32 internal _commandId = keccak256(bytes("commandId"));

    function setUp() public {
        _outputSettler = new OutputSettlerSimple();
        _token = new MockERC20("TEST", "TEST", 18);

        _axelarGateway = new AxelarGatewayMock();
        _axelarGasService = new AxelarGasServiceMock();
        _oracle = new AxelarOracle(address(_axelarGateway), address(_axelarGasService));

        _oracle.allowlistDestinationChain(_destination, true);
        _oracle.allowlistSourceChain(_origin, true);
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
            call: bytes(""),
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

        // Fill without submitting
        vm.expectRevert(abi.encodeWithSignature("NotAllPayloadsValid()"));
        _oracle.submit{ value: _gasPayment }(
            _destination, _recipientOracle.toString(), address(_outputSettler), payloads
        );
    }

    function test_fill_works_w() external {
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
                AxelarGatewayMock.callContract.selector,
                _destination,
                _recipientOracle.toString(),
                this.encodeMessageCalldata(address(_outputSettler).toIdentifier(), payloads)
            )
        );

        _oracle.submit{ value: _gasPayment }(
            _destination, _recipientOracle.toString(), address(_outputSettler), payloads
        );
    }

    function test_handle_works_w() external {
        test_handle_works(
            makeAddr("sender"),
            10 ** 18,
            makeAddr("recipient"),
            keccak256(bytes("orderId")),
            keccak256(bytes("solverIdentifier"))
        );
    }

    function test_handle_works(
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

        bytes32 hashedSourceChain = keccak256(abi.encodePacked(_origin));
        uint32 sourceChainId = uint32(uint256(hashedSourceChain) >> 224);
        address messageSender = makeAddr("messageSender");

        vm.expectEmit();
        emit OutputProven(sourceChainId, messageSender.toIdentifier(), application, payloadHashes[0]);

        vm.prank(address(_axelarGateway));
        _oracle.execute(_commandId, _origin, messageSender.toString(), message);

        assertTrue(_oracle.isProven(sourceChainId, messageSender.toIdentifier(), application, payloadHashes[0]));
    }

    receive() external payable { }
}
