/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { LibAddress } from "../../../../src/libs/LibAddress.sol";

import { MockAttester } from "../../../mocks/MockAttester.sol";
import { MockERC20 } from "../../../mocks/MockERC20.sol";
import { MockRouter } from "./mocks/MockRouter.sol";

import { ChainlinkCCIPOracle } from "../../../../src/integrations/oracles/chainlink/ChainlinkCCIPOracle.sol";
import { Client } from "../../../../src/integrations/oracles/chainlink/external/Client.sol";
import { BaseInputOracle } from "../../../../src/oracles/BaseInputOracle.sol";

contract ChainlinkCCIPOracleTest is Test {
    using LibAddress for address;

    MockRouter router;
    MockERC20 gasToken;
    MockAttester attester;

    address sender;

    uint256 constant fee = 12357911131719;

    ChainlinkCCIPOracle chainlinkCCIPOracle;

    function setUp() external {
        router = new MockRouter();
        router.setFee(fee);
        gasToken = new MockERC20("Link-ish", "LICK", 18);
        attester = new MockAttester();

        chainlinkCCIPOracle = new ChainlinkCCIPOracle(address(this), address(router));

        chainlinkCCIPOracle.setChainMap(15971525489660198786, 8453);
        chainlinkCCIPOracle.setChainMap(13204309965629103672, 534352);
        // Mock router always uses sepolia as origin of its messages.
        chainlinkCCIPOracle.setChainMap(16015286601757825753, 11155111);

        sender = makeAddr("sender");
    }

    // --- Test Submitting Intents --- //
    // Note that this calls calls the receive function. We just need it to not fail.

    function test_submit_batch() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        uint64[] memory destinationChainSelectors = new uint64[](1);
        destinationChainSelectors[0] = 15971525489660198786;
        bytes32[] memory receivers = new bytes32[](1);
        receivers[0] = address(chainlinkCCIPOracle).toIdentifier();

        uint256 refund = chainlinkCCIPOracle.submitBatch{
            value: fee
        }(destinationChainSelectors, receivers, new bytes(0), address(attester), payloads, address(0));
        vm.snapshotGasLastCall("oracle", "CCIPSubmitNativeBatchOfOne");
        assertEq(refund, 0);
    }

    function test_submit_batch_fee_token() external {
        gasToken.mint(sender, fee * 2);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        uint64[] memory destinationChainSelectors = new uint64[](1);
        destinationChainSelectors[0] = 15971525489660198786;
        bytes32[] memory receivers = new bytes32[](1);
        receivers[0] = address(chainlinkCCIPOracle).toIdentifier();

        vm.prank(sender);
        gasToken.approve(address(chainlinkCCIPOracle), fee * 2);
        vm.prank(sender);
        uint256 refund = chainlinkCCIPOracle.submitBatch(
            destinationChainSelectors, receivers, new bytes(0), address(attester), payloads, address(gasToken)
        );
        vm.snapshotGasLastCall("oracle", "CCIPSubmitTokenBatchOfOne");
        assertEq(refund, 0);

        // Do it again. This should skip the second approval.
        vm.prank(sender);
        refund = chainlinkCCIPOracle.submitBatch(
            destinationChainSelectors, receivers, new bytes(0), address(attester), payloads, address(gasToken)
        );
        assertEq(refund, 0);
    }

    function test_submit_single() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        uint256 refund = chainlinkCCIPOracle.submit{
            value: fee
        }(
            15971525489660198786,
            address(chainlinkCCIPOracle).toIdentifier(),
            new bytes(0),
            address(attester),
            payloads,
            address(0)
        );
        vm.snapshotGasLastCall("oracle", "CCIPSubmitNativeSingle");

        assertEq(refund, 0);
    }

    function test_submit_single_fee_token() external {
        gasToken.mint(sender, fee * 2);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        vm.prank(sender);
        gasToken.approve(address(chainlinkCCIPOracle), fee * 2);
        vm.prank(sender);
        uint256 refund = chainlinkCCIPOracle.submit(
            15971525489660198786,
            address(chainlinkCCIPOracle).toIdentifier(),
            new bytes(0),
            address(attester),
            payloads,
            address(gasToken)
        );
        vm.snapshotGasLastCall("oracle", "CCIPSubmitTokenSingle");
        assertEq(refund, 0);
    }

    function test_submit_batch_reuse_receiver() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        uint64[] memory destinationChainSelectors = new uint64[](2);
        destinationChainSelectors[0] = 15971525489660198786;
        destinationChainSelectors[1] = 13204309965629103672;
        bytes32[] memory receivers = new bytes32[](1);
        receivers[0] = address(chainlinkCCIPOracle).toIdentifier();

        chainlinkCCIPOracle.submitBatch{
            value: fee * 2
        }(destinationChainSelectors, receivers, new bytes(0), address(attester), payloads, address(0));
    }

    function test_submit_batch_refund() external {
        vm.deal(sender, fee * 2);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        uint64[] memory destinationChainSelectors = new uint64[](1);
        destinationChainSelectors[0] = 15971525489660198786;
        bytes32[] memory receivers = new bytes32[](1);
        receivers[0] = address(chainlinkCCIPOracle).toIdentifier();

        vm.prank(sender);
        uint256 refund = chainlinkCCIPOracle.submitBatch{
            value: fee * 2
        }(destinationChainSelectors, receivers, new bytes(0), address(attester), payloads, address(0));
        assertEq(refund, fee);

        assertEq(sender.balance, fee);
    }

    function test_submit_refund() external {
        vm.deal(sender, fee * 2);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        vm.prank(sender);
        uint256 refund = chainlinkCCIPOracle.submit{
            value: fee * 2
        }(
            15971525489660198786,
            address(chainlinkCCIPOracle).toIdentifier(),
            new bytes(0),
            address(attester),
            payloads,
            address(0)
        );
        assertEq(refund, fee);

        assertEq(sender.balance, fee);
    }

    function test_submit_batch_too_little_fee() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        uint64[] memory destinationChainSelectors = new uint64[](1);
        destinationChainSelectors[0] = 15971525489660198786;
        bytes32[] memory receivers = new bytes32[](1);
        receivers[0] = address(chainlinkCCIPOracle).toIdentifier();

        vm.expectRevert();
        uint256 refund = chainlinkCCIPOracle.submitBatch{
            value: fee - 1
        }(destinationChainSelectors, receivers, new bytes(0), address(attester), payloads, address(0));
        assertEq(refund, 0);
    }

    function test_submit_batch_refund_failed() external {
        vm.deal(sender, fee * 2);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        uint64[] memory destinationChainSelectors = new uint64[](1);
        destinationChainSelectors[0] = 15971525489660198786;
        bytes32[] memory receivers = new bytes32[](1);
        receivers[0] = address(chainlinkCCIPOracle).toIdentifier();

        // This contract has no receive function for the refund.
        vm.expectRevert();
        chainlinkCCIPOracle.submitBatch{
            value: fee * 2
        }(destinationChainSelectors, receivers, new bytes(0), address(attester), payloads, address(0));
    }

    function test_submit_batch_no_receivers() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));
        attester.setAttested(true, payloads[0]);

        uint64[] memory destinationChainSelectors = new uint64[](1);
        destinationChainSelectors[0] = 15971525489660198786;
        bytes32[] memory receivers = new bytes32[](0);

        vm.expectRevert(abi.encodeWithSignature("NoReceivers()"));
        chainlinkCCIPOracle.submitBatch{
            value: fee
        }(destinationChainSelectors, receivers, new bytes(0), address(attester), payloads, address(0));
    }

    function test_submit_batch_not_validated() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));

        uint64[] memory destinationChainSelectors = new uint64[](1);
        bytes32[] memory receivers = new bytes32[](1);

        vm.expectRevert(abi.encodeWithSignature("NotAllPayloadsValid()"));
        chainlinkCCIPOracle.submitBatch(
            destinationChainSelectors, receivers, new bytes(0), address(attester), payloads, address(0)
        );
    }

    function test_submit_single_not_validated() external {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(keccak256("payload"));

        vm.expectRevert(abi.encodeWithSignature("NotAllPayloadsValid()"));
        chainlinkCCIPOracle.submit(uint64(0), bytes32(0), new bytes(0), address(attester), payloads, address(0));
    }

    // --- Receive Messages --- //

    function test__ccipReceive(
        bytes[] calldata payloads
    ) external {
        // Setup test
        {
            for (uint256 i; i < payloads.length; ++i) {
                attester.setAttested(true, payloads[i]);
            }
        }

        {
            // Check whether the proper events where emitted.
            for (uint256 i; i < payloads.length; ++i) {
                vm.expectEmit();
                emit BaseInputOracle.OutputProven(
                    11155111,
                    address(chainlinkCCIPOracle).toIdentifier(),
                    address(attester).toIdentifier(),
                    keccak256(payloads[i])
                );
            }

            chainlinkCCIPOracle.submit{
                value: fee
            }(
                15971525489660198786,
                address(chainlinkCCIPOracle).toIdentifier(),
                Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: 200_000_000 })), // we need to give extra gas.
                address(attester),
                payloads,
                address(0)
            );
        }

        // Check Whether the attestations were correctly set.
        for (uint256 i; i < payloads.length; ++i) {
            bool proven = chainlinkCCIPOracle.isProven(
                11155111,
                address(chainlinkCCIPOracle).toIdentifier(),
                address(attester).toIdentifier(),
                keccak256(payloads[i])
            );
            assertEq(proven, true);
        }
    }
}
