// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { TransparentUpgradeableProxy } from
    "@openzeppelin-4/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { InterchainGasPaymaster } from "@hyperlane-xyz/hooks/igp/InterchainGasPaymaster.sol";
import { TypeCasts } from "@hyperlane-xyz/libs/TypeCasts.sol";

import { MockHyperlaneEnvironment } from "@hyperlane-xyz/mock/MockHyperlaneEnvironment.sol";
import { MockMailbox } from "@hyperlane-xyz/mock/MockMailbox.sol";

import { HyperlaneOracle } from "../../../src/oracles/hyperlane/HyperlaneOracle.sol";

import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { OutputSettlerCoin } from "../../../src/output/coin/OutputSettlerCoin.sol";
import { OutputSettlerCoin } from "../../../src/output/coin/OutputSettlerCoin.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

contract TestInterchainGasPaymaster is InterchainGasPaymaster {
    uint256 public gasPrice = 10;

    constructor() {
        initialize(msg.sender, msg.sender);
    }

    function quoteGasPayment(uint32, uint256 gasAmount) public view override returns (uint256) {
        return gasPrice * gasAmount;
    }

    function setGasPrice(
        uint256 _gasPrice
    ) public {
        gasPrice = _gasPrice;
    }

    function getDefaultGasUsage() public pure returns (uint256) {
        return DEFAULT_GAS_USAGE;
    }
}

event Dispatch(address indexed sender, uint32 indexed destination, bytes32 indexed recipient, bytes message);

contract HyperlaneOracleTest is Test {
    using TypeCasts for address;
    using LibAddress for address;

    MockHyperlaneEnvironment internal _environment;

    TestInterchainGasPaymaster internal _igp;

    HyperlaneOracle internal _originOracle;
    HyperlaneOracle internal _destinationOracle;

    bytes32 internal _originOracleB32;
    bytes32 internal _destinationOracleB32;

    uint256 _gasPaymentQuote;
    uint256 internal constant GAS_LIMIT = 60_000;

    address internal _admin = makeAddr("admin");
    address internal _owner = makeAddr("owner");
    address internal _sender = makeAddr("sender");

    uint32 internal _origin = 1;
    uint32 internal _destination = 2;

    OutputSettlerCoin _outputSettler;
    MockERC20 _token;

    function _deployProxiedRouter(MockMailbox mailbox, address owner) internal returns (HyperlaneOracle) {
        HyperlaneOracle implementation = new HyperlaneOracle(address(mailbox));

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            _admin,
            abi.encodeWithSelector(HyperlaneOracle.initialize.selector, address(0), address(0), owner)
        );

        return HyperlaneOracle(address(proxy));
    }

    function setUp() public {
        _environment = new MockHyperlaneEnvironment(_origin, _destination);

        _igp = new TestInterchainGasPaymaster();

        _gasPaymentQuote = _igp.quoteGasPayment(_destination, GAS_LIMIT);

        _originOracle = _deployProxiedRouter(_environment.mailboxes(_origin), _owner);
        _destinationOracle = _deployProxiedRouter(_environment.mailboxes(_destination), _owner);

        _environment.mailboxes(_origin).setDefaultHook(address(_igp));
        _environment.mailboxes(_destination).setDefaultHook(address(_igp));

        _originOracleB32 = TypeCasts.addressToBytes32(address(_originOracle));
        _destinationOracleB32 = TypeCasts.addressToBytes32(address(_destinationOracle));

        vm.startPrank(_owner);
        _originOracle.enrollRemoteRouter(_destination, _destinationOracleB32);
        _originOracle.setDestinationGas(_destination, GAS_LIMIT);

        _destinationOracle.enrollRemoteRouter(_origin, _originOracleB32);
        _destinationOracle.setDestinationGas(_origin, GAS_LIMIT);

        vm.stopPrank();

        _outputSettler = new OutputSettlerCoin();

        _token = new MockERC20("TEST", "TEST", 18);
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

    function hyperlaneMessage(
        uint32 originChain,
        bytes32 sender,
        uint32 destinationChain,
        bytes32 recipient,
        bytes32 application,
        bytes[] calldata payloads
    ) external view returns (bytes memory) {
        bytes memory encodedPayload = this.encodeMessageCalldata(application, payloads);
        return abi.encodePacked(
            _environment.mailboxes(originChain).VERSION(),
            _environment.mailboxes(originChain).nonce(),
            originChain,
            sender,
            destinationChain,
            recipient,
            encodedPayload
        );
    }

    function getMandatePayload(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) internal returns (MandateOutput memory, bytes memory) {
        _token.mint(sender, amount);
        vm.prank(sender);
        _token.approve(address(_outputSettler), amount);

        MandateOutput memory output = MandateOutput({
            oracle: address(_originOracle).toIdentifier(),
            settler: address(_outputSettler).toIdentifier(),
            token: bytes32(abi.encode(address(_token))),
            amount: amount,
            recipient: bytes32(abi.encode(recipient)),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solverIdentifier, orderId, uint32(block.timestamp), output
        );

        return (output, payload);
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
        (output, payloads[0]) = getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        // Fill without submitting
        vm.expectRevert(abi.encodeWithSignature("NotAllPayloadsValid()"));
        _destinationOracle.submit{ value: _gasPaymentQuote }(_destination, address(_outputSettler), payloads);
    }

    function test_submit_work(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) public {
        vm.assume(solverIdentifier != bytes32(0) && sender != address(0) && recipient != address(0));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        vm.expectCall(
            address(_token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(sender), recipient, amount)
        );

        vm.prank(sender);
        _outputSettler.fill(type(uint32).max, orderId, output, solverIdentifier);

        bytes memory expectedMessage = this.hyperlaneMessage(
            _origin, _originOracleB32, _destination, _destinationOracleB32, output.settler, payloads
        );

        vm.expectEmit();
        emit Dispatch(address(_originOracle), _destination, _destinationOracleB32, expectedMessage);
        _originOracle.submit{ value: _gasPaymentQuote }(_destination, address(_outputSettler), payloads);
        vm.snapshotGasLastCall("oracle", "hyperlaneOracleSubmit");
    }

    function test_handle_work(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) public {
        vm.assume(solverIdentifier != bytes32(0) && sender != address(0) && recipient != address(0));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        vm.expectCall(
            address(_token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(sender), recipient, amount)
        );

        vm.prank(sender);
        _outputSettler.fill(type(uint32).max, orderId, output, solverIdentifier);
        _originOracle.submit{ value: _gasPaymentQuote }(_destination, address(_outputSettler), payloads);

        _environment.processNextPendingMessage();

        (bytes32 application, bytes32[] memory payloadHashes) =
            this.getHashesOfEncodedPayloads(this.encodeMessageCalldata(output.settler, payloads));

        assertTrue(_destinationOracle.isProven(_origin, _originOracleB32, application, payloadHashes[0]));
    }

    receive() external payable { }
}
