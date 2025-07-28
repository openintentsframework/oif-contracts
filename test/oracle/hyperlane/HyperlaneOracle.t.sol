// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { OutputSettlerCoin } from "../../../src/output/coin/OutputSettlerCoin.sol";
import { OutputSettlerCoin } from "../../../src/output/coin/OutputSettlerCoin.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

import { HyperlaneOracle } from "../../../src/oracles/hyperlane/HyperlaneOracle.sol";
import { IPostDispatchHook } from
    "../../../src/oracles/hyperlane/external/hyperlane/interfaces/hooks/IPostDispatchHook.sol";
import { StandardHookMetadata } from "../../../src/oracles/hyperlane/external/hyperlane/libs/StandardHookMetadata.sol";

event OutputProven(uint256 chainid, bytes32 remoteIdentifier, bytes32 application, bytes32 payloadHash);

contract MailboxMock {
    uint256 public dispatchCounter;

    function localDomain() external pure returns (uint32) {
        return uint32(1);
    }

    function dispatch(
        uint32,
        bytes32,
        bytes calldata,
        bytes calldata,
        IPostDispatchHook
    ) external payable returns (bytes32 messageId) {
        dispatchCounter += 1;
        return keccak256(abi.encode(dispatchCounter));
    }

    function quoteDispatch(
        uint32,
        bytes32,
        bytes calldata,
        bytes calldata,
        IPostDispatchHook
    ) external pure returns (uint256 fee) {
        return 1e18;
    }
}

contract HyperlaneOracleTest is Test {
    using LibAddress for address;

    MailboxMock internal _mailbox;
    HyperlaneOracle internal _oracle;

    OutputSettlerCoin _outputSettler;
    MockERC20 _token;

    uint256 internal _gasPaymentQuote = 1e18;
    uint256 internal _gasLimit = 60000;
    uint32 internal _destination = 1;
    uint32 internal _origin = 2;
    address internal _recipientOracle = makeAddr("vegeta");

    function setUp() public {
        _outputSettler = new OutputSettlerCoin();
        _token = new MockERC20("TEST", "TEST", 18);

        _mailbox = new MailboxMock();
        _oracle = new HyperlaneOracle(address(_mailbox), makeAddr("kakaroto"), makeAddr("karpincho"));
    }

    function _getMandatePayload(
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
            oracle: address(_oracle).toIdentifier(),
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
        _oracle.submit{ value: _gasPaymentQuote }(
            _destination, _recipientOracle, _gasLimit, bytes("customMetadata"), address(_outputSettler), payloads
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

        vm.prank(sender);
        _outputSettler.fill(type(uint32).max, orderId, output, solverIdentifier);

        bytes memory customMetadata = bytes("customMetadata");

        vm.expectCall(
            address(_mailbox),
            abi.encodeWithSelector(
                MailboxMock.dispatch.selector,
                _destination,
                _recipientOracle.toIdentifier(),
                this.encodeMessageCalldata(output.settler, payloads),
                StandardHookMetadata.formatMetadata(0, _gasLimit, address(this), customMetadata),
                _oracle.hook()
            )
        );

        _oracle.submit{ value: _gasPaymentQuote }(
            _destination, _recipientOracle, _gasLimit, customMetadata, address(_outputSettler), payloads
        );
        vm.snapshotGasLastCall("oracle", "hyperlaneOracleSubmit");
    }

    function test_submit_customHook_works_w() external {
        test_submit_customHook_works(
            makeAddr("sender"),
            10 ** 18,
            makeAddr("recipient"),
            keccak256(bytes("orderId")),
            keccak256(bytes("solverIdentifier")),
            makeAddr("customHook")
        );
    }

    function test_submit_customHook_works(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier,
        address customHook
    ) public {
        vm.assume(solverIdentifier != bytes32(0) && sender != address(0) && recipient != address(0));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        vm.expectCall(
            address(_token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(sender), recipient, amount)
        );

        vm.prank(sender);
        _outputSettler.fill(type(uint32).max, orderId, output, solverIdentifier);

        bytes memory customMetadata = bytes("customMetadata");

        vm.expectCall(
            address(_mailbox),
            abi.encodeWithSelector(
                MailboxMock.dispatch.selector,
                _destination,
                _recipientOracle.toIdentifier(),
                this.encodeMessageCalldata(output.settler, payloads),
                StandardHookMetadata.formatMetadata(0, _gasLimit, address(this), customMetadata),
                IPostDispatchHook(customHook)
            )
        );

        _oracle.submit{ value: _gasPaymentQuote }(
            _destination,
            _recipientOracle,
            _gasLimit,
            customMetadata,
            IPostDispatchHook(customHook),
            address(_outputSettler),
            payloads
        );
        vm.snapshotGasLastCall("oracle", "hyperlaneOracleSubmitCustomHook");
    }

    function test_handle_onlyMailbox(
        address sender,
        uint256 amount,
        address recipient,
        bytes32 orderId,
        bytes32 solverIdentifier
    ) external {
        vm.assume(solverIdentifier != bytes32(0) && sender != address(0) && recipient != address(0));

        MandateOutput memory output;
        bytes[] memory payloads = new bytes[](1);
        (output, payloads[0]) = _getMandatePayload(sender, amount, recipient, orderId, solverIdentifier);

        bytes memory message = this.encodeMessageCalldata(output.settler, payloads);

        vm.expectRevert(abi.encodeWithSignature("SenderNotMailbox()"));
        _oracle.handle(_origin, makeAddr("messageSender").toIdentifier(), message);
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

        bytes memory message = this.encodeMessageCalldata(output.settler, payloads);

        (bytes32 application, bytes32[] memory payloadHashes) = this.getHashesOfEncodedPayloads(message);

        bytes32 messageSender = makeAddr("messageSender").toIdentifier();

        vm.expectEmit();
        emit OutputProven(_origin, messageSender, application, payloadHashes[0]);

        vm.prank(address(_mailbox));
        _oracle.handle(_origin, messageSender, message);
        vm.snapshotGasLastCall("oracle", "hyperlaneOracleHandle");

        assertTrue(_oracle.isProven(_origin, messageSender, application, payloadHashes[0]));
    }

    function test_quoteGasPayment_works() public {
        bytes memory customMetadata = bytes("customMetadata");

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = bytes("some payload");

        vm.expectCall(
            address(_mailbox),
            abi.encodeWithSelector(
                MailboxMock.quoteDispatch.selector,
                _destination,
                _recipientOracle.toIdentifier(),
                this.encodeMessageCalldata(address(_outputSettler).toIdentifier(), payloads),
                StandardHookMetadata.formatMetadata(0, _gasLimit, address(this), customMetadata),
                _oracle.hook()
            )
        );

        _oracle.quoteGasPayment(
            _destination, _recipientOracle, _gasLimit, customMetadata, address(_outputSettler), payloads
        );
    }

    function test_quoteGasPayment_customHook_works() public {
        bytes memory customMetadata = bytes("customMetadata");
        IPostDispatchHook customHook = IPostDispatchHook(makeAddr("customHook"));

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = bytes("some payload");

        vm.expectCall(
            address(_mailbox),
            abi.encodeWithSelector(
                MailboxMock.quoteDispatch.selector,
                _destination,
                _recipientOracle.toIdentifier(),
                this.encodeMessageCalldata(address(_outputSettler).toIdentifier(), payloads),
                StandardHookMetadata.formatMetadata(0, _gasLimit, address(this), customMetadata),
                customHook
            )
        );

        _oracle.quoteGasPayment(
            _destination, _recipientOracle, _gasLimit, customMetadata, customHook, address(_outputSettler), payloads
        );
    }

    receive() external payable { }
}
