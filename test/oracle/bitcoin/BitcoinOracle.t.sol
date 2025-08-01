// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { BtcPrism } from "bitcoinprism-evm/src/BtcPrism.sol";
import { Endian } from "bitcoinprism-evm/src/Endian.sol";
import { IBtcPrism } from "bitcoinprism-evm/src/interfaces/IBtcPrism.sol";
import { BtcProof, BtcTxProof, ScriptMismatch } from "bitcoinprism-evm/src/library/BtcProof.sol";
import { BtcScript } from "bitcoinprism-evm/src/library/BtcScript.sol";

import { MandateOutput, MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { BitcoinOracle } from "../../../src/oracles/bitcoin/BitcoinOracle.sol";
import { WormholeOracle } from "../../../src/oracles/wormhole/WormholeOracle.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { ExportedMessages } from "../wormhole/WormholeOracle.submit.t.sol";
import "./blocksinfo.t.sol";

contract BitcoinOracleHarness is BitcoinOracle {
    constructor(
        address _lightClient,
        address disputedOrderFeeDestination,
        address collateralToken,
        uint64 _collateralMultiplier
    ) payable BitcoinOracle(_lightClient, disputedOrderFeeDestination, collateralToken, _collateralMultiplier) { }

    function getProofPeriod(
        uint256 confirmations
    ) external pure returns (uint256) {
        return _getProofPeriod(confirmations);
    }
}

contract BitcoinOracleTest is Test {
    event OutputClaimed(bytes32 indexed orderId, bytes32 outputId);

    uint32 maxTimeIncrement = 1 days - 1;

    MockERC20 token;

    WormholeOracle wormholeOracle;

    BtcPrism btcPrism;
    BitcoinOracleHarness bitcoinOracle;

    uint256 multiplier = 1e10 * 100;

    function setUp() public {
        ExportedMessages messages = new ExportedMessages();
        wormholeOracle = new WormholeOracle(address(this), address(messages));

        token = new MockERC20("Mock ERC20", "MOCK", 18);

        btcPrism = new BtcPrism(BLOCK_HEIGHT, BLOCK_HASH, BLOCK_TIME, EXPECTED_TARGET, false);

        bitcoinOracle = new BitcoinOracleHarness(address(btcPrism), address(0), address(token), uint64(multiplier));
    }

    // --- Time To Confirmation --- //

    function test_proof_period() external view {
        assertEq(bitcoinOracle.getProofPeriod(1), 69 minutes + 7 minutes);
        assertEq(bitcoinOracle.getProofPeriod(2), 93 minutes + 7 minutes);
        assertEq(bitcoinOracle.getProofPeriod(3), 112 minutes + 7 minutes);
        assertEq(bitcoinOracle.getProofPeriod(4), 131 minutes + 7 minutes);
        assertEq(bitcoinOracle.getProofPeriod(5), 148 minutes + 7 minutes);
        assertEq(bitcoinOracle.getProofPeriod(6), 165 minutes + 7 minutes);
        assertEq(bitcoinOracle.getProofPeriod(7), 181 minutes + 7 minutes);
    }

    function test_proof_period_n(
        uint8 n
    ) external view {
        assertEq(bitcoinOracle.getProofPeriod(7 + uint256(n)), 181 minutes + 7 minutes + uint256(n) * 15 minutes);
    }

    // --- Optimistic Component --- //
    //  TODO: mock _resolveClaimed

    //-- Claim

    /// forge-config: default.isolate = true
    function test_claim_gas() external {
        test_claim(keccak256(bytes("solver")), keccak256(bytes("orderId")), 10 ** 18, makeAddr("caller"));
    }

    function test_claim(bytes32 solver, bytes32 orderId, uint64 amount, address caller) public {
        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        bytes32 outputId = bitcoinOracle.outputIdentifier(output);

        if (orderId == bytes32(0) || solver == bytes32(0)) {
            vm.expectRevert(abi.encodeWithSignature("ZeroValue()"));
            vm.prank(caller);
            bitcoinOracle.claim(solver, orderId, output);
            return;
        }

        vm.expectEmit();
        emit OutputClaimed(orderId, bitcoinOracle.outputIdentifier(output));

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);
        vm.snapshotGasLastCall("oracle", "bitcoinOutputClaim");

        (bytes32 solver_, uint32 claimTimestamp_, uint64 multiplier_, address sponsor_, address disputer_,) =
            bitcoinOracle._claimedOrder(orderId, outputId);

        assertEq(solver, solver_);
        assertEq(block.timestamp, claimTimestamp_);
        assertEq(multiplier, uint256(multiplier_));
        assertEq(caller, sponsor_);
        assertEq(address(0), disputer_);
    }

    function test_revert_claim_solver_0(bytes32 orderId, address caller, uint64 amount) external {
        bytes32 solver = bytes32(0);
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("ZeroValue()"));
        bitcoinOracle.claim(solver, orderId, output);
    }

    function test_revert_claim_amount_0(bytes32 solver, uint64 amount, address caller) external {
        bytes32 orderId = bytes32(0);
        vm.assume(solver != bytes32(0));
        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("ZeroValue()"));
        bitcoinOracle.claim(solver, orderId, output);
    }

    function test_revert_claim_twice(bytes32 solver, bytes32 orderId, uint64 amount, address caller) external {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed(bytes32)", solver));
        bitcoinOracle.claim(solver, orderId, output);
    }

    //-- Dispute

    /// forge-config: default.isolate = true
    function test_dispute_gas() external {
        test_dispute(
            keccak256(bytes("solver")), keccak256(bytes("orderId")), 10 ** 18, makeAddr("caller"), makeAddr("disputer")
        );
    }

    function test_dispute(bytes32 solver, bytes32 orderId, uint64 amount, address caller, address disputer) public {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });
        bytes32 outputId = bitcoinOracle.outputIdentifier(output);

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        uint256 disputeAmount = collateralAmount * bitcoinOracle.DISPUTED_ORDER_FEE_FRACTION();
        token.mint(disputer, disputeAmount);
        vm.prank(disputer);
        token.approve(address(bitcoinOracle), disputeAmount);

        vm.prank(disputer);
        bitcoinOracle.dispute(orderId, output);
        vm.snapshotGasLastCall("oracle", "bitcoinOutputDispute");

        (
            bytes32 solver_,
            uint32 claimTimestamp_,
            uint64 multiplier_,
            address sponsor_,
            address disputer_,
            uint32 disputeTimestamp_
        ) = bitcoinOracle._claimedOrder(orderId, outputId);

        assertEq(solver, solver_);
        assertEq(block.timestamp, claimTimestamp_);
        assertEq(multiplier, uint256(multiplier_));
        assertEq(caller, sponsor_);
        assertEq(disputer, disputer_);
        assertEq(block.timestamp + 93 minutes, disputeTimestamp_);
    }

    function test_revert_dispute_too_late(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        uint256 disputeAmount = collateralAmount * bitcoinOracle.DISPUTED_ORDER_FEE_FRACTION();
        token.mint(disputer, disputeAmount);
        vm.prank(disputer);
        token.approve(address(bitcoinOracle), disputeAmount);

        vm.warp(block.timestamp + 1 days);

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSignature("TooLate()"));
        bitcoinOracle.dispute(orderId, output);
    }

    function test_revert_dispute_no_collateral(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(amount != 0);

        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSignature("TransferFromFailed()"));
        bitcoinOracle.dispute(orderId, output);
    }

    function test_revert_dispute_not_claimed(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address disputer
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = amount * multiplier;
        uint256 disputeAmount = collateralAmount * bitcoinOracle.DISPUTED_ORDER_FEE_FRACTION();
        token.mint(disputer, disputeAmount);
        vm.prank(disputer);
        token.approve(address(bitcoinOracle), disputeAmount);

        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSignature("NotClaimed()"));
        bitcoinOracle.dispute(orderId, output);
    }

    function test_revert_dispute_twice(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        uint256 disputeAmount = collateralAmount * bitcoinOracle.DISPUTED_ORDER_FEE_FRACTION();
        token.mint(disputer, disputeAmount);
        vm.prank(disputer);
        token.approve(address(bitcoinOracle), disputeAmount);

        vm.prank(disputer);
        bitcoinOracle.dispute(orderId, output);

        vm.expectRevert(abi.encodeWithSignature("AlreadyDisputed(address)", disputer));
        bitcoinOracle.dispute(orderId, output);
    }

    //-- Optimistic Verification

    /// forge-config: default.isolate = true
    function test_optimistically_verify_gas() external {
        test_optimistically_verify(
            keccak256(bytes("solver")), keccak256(bytes("orderId")), 10 ** 18, makeAddr("caller"), makeAddr("disputer")
        );
    }

    function test_optimistically_verify(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) public {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });
        bytes32 outputId = bitcoinOracle.outputIdentifier(output);

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        vm.warp(block.timestamp + 131 minutes + 1);

        bitcoinOracle.optimisticallyVerify(orderId, output);
        vm.snapshotGasLastCall("oracle", "bitcoinOPVerify");

        (
            bytes32 solver_,
            uint32 claimTimestamp_,
            uint64 multiplier_,
            address sponsor_,
            address disputer_,
            uint32 disputeTimestamp_
        ) = bitcoinOracle._claimedOrder(orderId, outputId);

        assertEq(solver, solver_);
        assertEq(0, claimTimestamp_);
        assertEq(0, uint256(multiplier_));
        assertEq(address(0), sponsor_);
        assertEq(address(0), disputer_);
        assertEq(0, disputeTimestamp_);
    }

    function test_revert_op_verify_disputed(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        uint256 disputeAmount = collateralAmount * bitcoinOracle.DISPUTED_ORDER_FEE_FRACTION();
        token.mint(disputer, disputeAmount);
        vm.prank(disputer);
        token.approve(address(bitcoinOracle), disputeAmount);

        vm.prank(disputer);
        bitcoinOracle.dispute(orderId, output);

        vm.warp(block.timestamp + 131 minutes + 1);

        vm.expectRevert(abi.encodeWithSignature("Disputed()"));
        bitcoinOracle.optimisticallyVerify(orderId, output);
    }

    function test_revert_op_verify_not_claimed(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        vm.warp(block.timestamp + 131 minutes + 1);

        vm.expectRevert(abi.encodeWithSignature("NotClaimed()"));
        bitcoinOracle.optimisticallyVerify(orderId, output);
    }

    function test_revert_op_verify_too_early(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(bitcoinOracle));
        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        vm.warp(block.timestamp + 131 minutes);

        vm.expectRevert(abi.encodeWithSignature("TooEarly()"));
        bitcoinOracle.optimisticallyVerify(orderId, output);
    }

    //-- Finalise Dispute

    /// forge-config: default.isolate = true
    function test_finalise_dispute_gas() external {
        test_finalise_dispute(
            keccak256(bytes("solver")), keccak256(bytes("orderId")), 10 ** 18, makeAddr("caller"), makeAddr("disputer")
        );
    }

    function test_finalise_dispute(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) public {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });
        bytes32 outputId = bitcoinOracle.outputIdentifier(output);

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        uint256 disputeAmount = collateralAmount * bitcoinOracle.DISPUTED_ORDER_FEE_FRACTION();
        token.mint(disputer, disputeAmount);
        vm.prank(disputer);
        token.approve(address(bitcoinOracle), disputeAmount);

        vm.prank(disputer);
        bitcoinOracle.dispute(orderId, output);

        (
            bytes32 solver_,
            uint32 claimTimestamp_,
            uint64 multiplier_,
            address sponsor_,
            address disputer_,
            uint32 disputeTimestamp_
        ) = bitcoinOracle._claimedOrder(orderId, outputId);

        assertEq(solver, solver_);
        assertEq(block.timestamp, claimTimestamp_);
        assertEq(multiplier, uint256(multiplier_));
        assertEq(caller, sponsor_);
        assertEq(disputer, disputer_);
        assertEq(block.timestamp + 93 minutes, disputeTimestamp_);

        vm.warp(block.timestamp + 1 days);
        bitcoinOracle.finaliseDispute(orderId, output);
        vm.snapshotGasLastCall("oracle", "bitcoinFinaliseDispute");

        (solver_, claimTimestamp_, multiplier_, sponsor_, disputer_, disputeTimestamp_) =
            bitcoinOracle._claimedOrder(orderId, outputId);

        assertEq(solver, solver_);
        assertEq(0, claimTimestamp_);
        assertEq(0, uint256(multiplier_));
        assertEq(address(0), sponsor_);
        assertEq(address(0), disputer_);
        assertEq(0, disputeTimestamp_);
    }

    function test_revert_finalise_dispute_too_early(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        uint256 disputeAmount = collateralAmount * bitcoinOracle.DISPUTED_ORDER_FEE_FRACTION();
        token.mint(disputer, disputeAmount);
        vm.prank(disputer);
        token.approve(address(bitcoinOracle), disputeAmount);

        vm.prank(disputer);
        bitcoinOracle.dispute(orderId, output);

        vm.warp(block.timestamp + 69 minutes);

        vm.expectRevert(abi.encodeWithSignature("TooEarly()"));
        bitcoinOracle.finaliseDispute(orderId, output);
    }

    function test_revert_finalise_dispute_not_disputed(
        bytes32 solver,
        bytes32 orderId,
        uint64 amount,
        address caller,
        address disputer
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(disputer != address(0));
        vm.assume(caller != address(0));
        vm.assume(orderId != bytes32(0));

        vm.assume(caller != address(token));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(bitcoinOracle)))),
            settler: bytes32(uint256(uint160(address(bitcoinOracle)))),
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: uint256(amount),
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        // We need the
        uint256 collateralAmount = amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(abi.encodeWithSignature("NotDisputed()"));
        bitcoinOracle.finaliseDispute(orderId, output);
    }

    // --- Transaction Verification --- //

    /// forge-config: default.isolate = true
    function test_verify_gas() external {
        test_verify_as_filler(keccak256(bytes("solver")), keccak256(bytes("orderId")), makeAddr("caller"));
    }

    function test_verify_as_filler(bytes32 solver, bytes32 orderId, address caller) public {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));
        vm.assume(caller != address(bitcoinOracle));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(this)))),
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.expectEmit();
        emit OutputClaimed(orderId, bitcoinOracle.outputIdentifier(output));

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        // Check for a refund of collateral.
        assertEq(token.balanceOf(address(bitcoinOracle)), collateralAmount);
        assertEq(token.balanceOf(caller), 0);
        {
            BtcTxProof memory inclusionProof = BtcTxProof({
                blockHeader: BLOCK_HEADER,
                txId: TX_ID,
                txIndex: TX_INDEX,
                txMerkleProof: TX_MERKLE_PROOF,
                rawTx: RAW_TX
            });

            bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
            vm.snapshotGasLastCall("oracle", "bitcoinVerify");
        }
        // Check if the payload has been correctly stored for both a input oracle and output oracle.

        // Output oracle (as filler)
        bytes memory payload =
            MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, uint32(BLOCK_TIME), output);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        bool fillerValid = bitcoinOracle.arePayloadsValid(payloads);
        assertEq(fillerValid, true);

        // Check for a refund of collateral.
        assertEq(token.balanceOf(caller), collateralAmount);
        assertEq(token.balanceOf(address(bitcoinOracle)), 0);

        // TODO: implement this check without stack too deep
        // Check that storage has been correctly updated.
        // (bytes32 solver_, uint32 claimTimestamp_, uint64 multiplier_, address sponsor_, address disputer_,) =
        //     bitcoinOracle._claimedOrder(orderId, outputId);

        // assertEq(bytes32(0), solver_);
        // assertEq(0, claimTimestamp_);
        // assertEq(0, uint256(multiplier_));
        // assertEq(address(0), sponsor_);
        // assertEq(address(0), disputer_);
    }

    function test_verify_as_oracle(bytes32 solver, bytes32 orderId, address caller) public {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));
        vm.assume(caller != address(bitcoinOracle));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.expectEmit();
        emit OutputClaimed(orderId, bitcoinOracle.outputIdentifier(output));

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        // Check for a refund of collateral.
        assertEq(token.balanceOf(address(bitcoinOracle)), collateralAmount);
        assertEq(token.balanceOf(caller), 0);
        {
            BtcTxProof memory inclusionProof = BtcTxProof({
                blockHeader: BLOCK_HEADER,
                txId: TX_ID,
                txIndex: TX_INDEX,
                txMerkleProof: TX_MERKLE_PROOF,
                rawTx: RAW_TX
            });

            bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
            vm.snapshotGasLastCall("oracle", "bitcoinVerify");
        }
        // Input Oracle (as oracle)
        bytes memory payload =
            MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, uint32(BLOCK_TIME), output);
        bool oracleValid =
            bitcoinOracle.isProven(block.chainid, bitcoinOracleBytes32, bitcoinOracleBytes32, keccak256(payload));
        assertEq(oracleValid, true);

        // Check for a refund of collateral.
        assertEq(token.balanceOf(caller), collateralAmount);
        assertEq(token.balanceOf(address(bitcoinOracle)), 0);

        // TODO: implement this check without stack too deep
        // Check that storage has been correctly updated.
        // (bytes32 solver_, uint32 claimTimestamp_, uint64 multiplier_, address sponsor_, address disputer_,) =
        //     bitcoinOracle._claimedOrder(orderId, outputId);

        // assertEq(bytes32(0), solver_);
        // assertEq(0, claimTimestamp_);
        // assertEq(0, uint256(multiplier_));
        // assertEq(address(0), sponsor_);
        // assertEq(address(0), disputer_);

        // Try to claim the transaction again.
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed(bytes32)", solver));
        bitcoinOracle.claim(keccak256(abi.encodePacked(solver)), orderId, output);
    }

    function test_verify_custom_multiplier_as_filler(
        bytes32 solver,
        bytes32 orderId,
        address caller,
        uint8 custom_multiplier
    ) external {
        vm.assume(custom_multiplier != 0);
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));
        vm.assume(caller != address(bitcoinOracle));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(this)))),
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: bytes.concat(bytes1(0xB0), bytes32(uint256(custom_multiplier)))
        });

        uint256 collateralAmount = output.amount * uint256(custom_multiplier);
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        bytes32 outputId = bitcoinOracle.outputIdentifier(output);

        vm.expectEmit();
        emit OutputClaimed(orderId, bitcoinOracle.outputIdentifier(output));

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        (,, uint64 multiplier_,,,) = bitcoinOracle._claimedOrder(orderId, outputId);

        assertEq(custom_multiplier, multiplier_);

        // Check for a refund of collateral.
        assertEq(token.balanceOf(address(bitcoinOracle)), collateralAmount);
        assertEq(token.balanceOf(caller), 0);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);

        // Check if the payload has been correctly stored for both a input oracle and output oracle.

        // Output oracle (as filler)
        bytes memory payload =
            MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, uint32(BLOCK_TIME), output);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        bool fillerValid = bitcoinOracle.arePayloadsValid(payloads);
        assertEq(fillerValid, true);
    }

    function test_verify_custom_multiplier_as_oracle(
        bytes32 solver,
        bytes32 orderId,
        address caller,
        uint8 custom_multiplier
    ) external {
        vm.assume(custom_multiplier != 0);
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));
        vm.assume(caller != address(bitcoinOracle));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: bytes.concat(bytes1(0xB0), bytes32(uint256(custom_multiplier)))
        });

        uint256 collateralAmount = output.amount * uint256(custom_multiplier);
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        bytes32 outputId = bitcoinOracle.outputIdentifier(output);

        vm.expectEmit();
        emit OutputClaimed(orderId, bitcoinOracle.outputIdentifier(output));

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        (,, uint64 multiplier_,,,) = bitcoinOracle._claimedOrder(orderId, outputId);

        assertEq(custom_multiplier, multiplier_);

        // Check for a refund of collateral.
        assertEq(token.balanceOf(address(bitcoinOracle)), collateralAmount);
        assertEq(token.balanceOf(caller), 0);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);

        // Input Oracle (as oracle)
        bytes memory payload =
            MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, uint32(BLOCK_TIME), output);
        bool oracleValid =
            bitcoinOracle.isProven(block.chainid, bitcoinOracleBytes32, bitcoinOracleBytes32, keccak256(payload));
        assertEq(oracleValid, true);
    }

    function test_verify_after_dispute(bytes32 solver, bytes32 orderId, address caller, address disputer) external {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));
        vm.assume(caller != address(bitcoinOracle));
        vm.assume(disputer != address(0));
        vm.assume(disputer != address(bitcoinOracle));
        vm.assume(disputer != address(token));
        vm.assume(caller != disputer);

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        uint256 disputeAmount = collateralAmount * bitcoinOracle.DISPUTED_ORDER_FEE_FRACTION();
        token.mint(disputer, disputeAmount);
        vm.prank(disputer);
        token.approve(address(bitcoinOracle), disputeAmount);

        vm.prank(disputer);
        bitcoinOracle.dispute(orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
    }

    function test_revert_verify_no_claim(bytes32 solver, bytes32 orderId, address caller) external {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));
        vm.assume(caller != address(bitcoinOracle));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        vm.expectRevert(abi.encodeWithSignature("NotClaimed()"));
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
    }

    /// forge-config: default.isolate = true
    function test_verify_embed_gas() external {
        test_verify_embed_as_filler(keccak256(bytes("solver")), keccak256(bytes("orderId")), makeAddr("caller"));
    }

    function test_verify_embed_as_filler(bytes32 solver, bytes32 orderId, address caller) public {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));
        vm.assume(caller != address(bitcoinOracle));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(this)))),
            settler: bitcoinOracleBytes32,
            token: bytes32(
                bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", EMBED_UTXO_TYPE)
            ),
            recipient: bytes32(EMBED_PHASH),
            amount: EMBED_SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: EMBEDDED_DATA_RETURN,
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.expectEmit();
        emit OutputClaimed(orderId, bitcoinOracle.outputIdentifier(output));

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: EMBED_TX_ID,
            txIndex: EMBED_TX_INDEX,
            txMerkleProof: EMBED_TX_MERKLE_PROOF,
            rawTx: EMBED_RAW_TX
        });

        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, EMBED_TX_OUTPUT_INDEX);
        vm.snapshotGasLastCall("oracle", "bitcoinVerifyWithEmbed");

        // Check if the payload has been correctly stored for both a input oracle and output oracle.

        // Output oracle (as filler)
        bytes memory payload =
            MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, uint32(BLOCK_TIME), output);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        bool fillerValid = bitcoinOracle.arePayloadsValid(payloads);
        assertEq(fillerValid, true);
    }

    function test_verify_embed_as_oracle(bytes32 solver, bytes32 orderId, address caller) public {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));
        vm.assume(caller != address(bitcoinOracle));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(
                bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", EMBED_UTXO_TYPE)
            ),
            recipient: bytes32(EMBED_PHASH),
            amount: EMBED_SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: EMBEDDED_DATA_RETURN,
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.expectEmit();
        emit OutputClaimed(orderId, bitcoinOracle.outputIdentifier(output));

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: EMBED_TX_ID,
            txIndex: EMBED_TX_INDEX,
            txMerkleProof: EMBED_TX_MERKLE_PROOF,
            rawTx: EMBED_RAW_TX
        });

        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, EMBED_TX_OUTPUT_INDEX);
        vm.snapshotGasLastCall("oracle", "bitcoinVerifyWithEmbed");

        // Input Oracle (as oracle)
        bytes memory payload =
            MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, uint32(BLOCK_TIME), output);
        bool oracleValid =
            bitcoinOracle.isProven(block.chainid, bitcoinOracleBytes32, bitcoinOracleBytes32, keccak256(payload));
        assertEq(oracleValid, true);
    }

    function test_revert_script_mismatch_verify_embed(
        bytes32 solver,
        bytes32 orderId,
        address caller,
        bytes calldata remoteCall
    ) external {
        vm.assume(keccak256(EMBEDDED_DATA_RETURN) != keccak256(remoteCall));
        vm.assume(remoteCall.length <= type(uint32).max);
        vm.assume(remoteCall.length > 0);

        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(
                bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", EMBED_UTXO_TYPE)
            ),
            recipient: bytes32(EMBED_PHASH),
            amount: EMBED_SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: remoteCall,
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: EMBED_TX_ID,
            txIndex: EMBED_TX_INDEX,
            txMerkleProof: EMBED_TX_MERKLE_PROOF,
            rawTx: EMBED_RAW_TX
        });

        vm.expectRevert(
            abi.encodeWithSignature(
                "ScriptMismatch(bytes,bytes)", BtcScript.embedOpReturn(remoteCall), EMBEDDED_DATA_OP_RETURN_SCRIPT
            )
        );
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, EMBED_TX_OUTPUT_INDEX);
    }

    function test_revert_txo_mismatch_verify_embed(
        bytes32 solver,
        bytes32 orderId,
        address caller,
        bytes calldata remoteCall
    ) external {
        vm.assume(keccak256(EMBEDDED_DATA_RETURN) != keccak256(remoteCall));
        vm.assume(remoteCall.length <= type(uint32).max);
        vm.assume(remoteCall.length > 0);

        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", bytes1(0x04))),
            recipient: bytes32(EMBED_PHASH),
            amount: EMBED_SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: remoteCall,
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: EMBED_TX_ID,
            txIndex: EMBED_TX_INDEX,
            txMerkleProof: EMBED_TX_MERKLE_PROOF,
            rawTx: EMBED_RAW_TX
        });

        vm.expectRevert();
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, EMBED_TX_OUTPUT_INDEX);
    }

    function test_verify_with_previous_block_header(bytes32 solver, bytes32 orderId, address caller) external {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(this)))),
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX, PREV_BLOCK_HEADER);

        // Output oracle (as filler)
        bytes memory payload =
            MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, uint32(PREV_BLOCK_TIME), output);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        bool fillerValid = bitcoinOracle.arePayloadsValid(payloads);
        assertEq(fillerValid, true);
    }

    function test_revert_verify_with_broken_previous_block_header(
        bytes32 solver,
        bytes32 orderId,
        address caller
    ) external {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        vm.expectRevert();
        bitcoinOracle.verify(
            orderId,
            output,
            BLOCK_HEIGHT,
            inclusionProof,
            TX_OUTPUT_INDEX,
            abi.encodePacked(PREV_BLOCK_HEADER, bytes1(0x01))
        );
    }

    function test_verify_after_block_sumbission(bytes32 solver, bytes32 orderId, address caller) public {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        IBtcPrism(bitcoinOracle.LIGHT_CLIENT()).submit(NEXT_BLOCK_HEIGHT, NEXT_BLOCK_HEADER);

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bytes32(uint256(uint160(address(this)))),
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);

        // Output oracle (as filler)
        bytes memory payload =
            MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, uint32(BLOCK_TIME), output);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        bool fillerValid = bitcoinOracle.arePayloadsValid(payloads);
        assertEq(fillerValid, true);
    }

    /// --- Invalid test cases --- ///

    function test_revert_bitcoin_transaction_too_old(bytes32 solver, bytes32 orderId, address caller) public {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        IBtcPrism(bitcoinOracle.LIGHT_CLIENT()).submit(NEXT_BLOCK_HEIGHT, NEXT_BLOCK_HEADER);

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME + 1 days + 1);

        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        vm.expectRevert(abi.encodeWithSignature("TooLate()"));
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
    }

    function test_revert_bad_amount(bytes32 solver, bytes32 orderId, address caller, uint64 diffAmount) public {
        vm.assume(diffAmount != 0);

        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        IBtcPrism(bitcoinOracle.LIGHT_CLIENT()).submit(NEXT_BLOCK_HEIGHT, NEXT_BLOCK_HEADER);

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT + diffAmount,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        vm.expectRevert(abi.encodeWithSignature("BadAmount()"));
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
    }

    function test_revert_block_hash_mismatch(bytes32 solver, bytes32 orderId, address caller) public {
        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        bytes32 expectedBlockHash = this._getBlockHashFromHeader(NEXT_BLOCK_HEADER);
        bytes32 actualBlockHash = this._getPreviousBlockHashFromHeader(inclusionProof.blockHeader);
        vm.expectRevert(
            abi.encodeWithSignature("BlockhashMismatch(bytes32,bytes32)", actualBlockHash, expectedBlockHash)
        );
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX, NEXT_BLOCK_HEADER);
    }

    function test_revert_bad_token(
        bytes32 solver,
        bytes32 orderId,
        address caller,
        bytes32 badTokenIdentifier
    ) public {
        vm.assume(bytes30(badTokenIdentifier) != 0x000000000000000000000000BC0000000000000000000000000000000000);

        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: badTokenIdentifier,
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        vm.expectRevert(abi.encodeWithSignature("BadTokenFormat()"));
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
    }

    function test_revert_wrong_utxo_type(
        bytes32 solver,
        bytes32 orderId,
        address caller,
        bytes1 wrongUTXOType
    ) public {
        vm.assume(wrongUTXOType != UTXO_TYPE);

        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", wrongUTXOType)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        vm.expectRevert();
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
    }

    function test_revert_wrong_utxo_type_P2WPKH(bytes32 solver, bytes32 orderId, address caller) public {
        bytes1 wrongUTXOType = 0x03;

        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", wrongUTXOType)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        vm.expectRevert();
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
    }

    function test_revert_no_block(bytes32 solver, bytes32 orderId, address caller, uint256 blockHeight) public {
        vm.assume(blockHeight > BLOCK_HEIGHT);

        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(bytes.concat(hex"000000000000000000000000BC000000000000000000000000000000000000", UTXO_TYPE)),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        vm.expectRevert(abi.encodeWithSignature("NoBlock(uint256,uint256)", BLOCK_HEIGHT, blockHeight));
        bitcoinOracle.verify(orderId, output, blockHeight, inclusionProof, TX_OUTPUT_INDEX);
    }

    function test_revert_not_enough_confirmations(
        bytes32 solver,
        bytes32 orderId,
        address caller,
        bytes1 confirmations
    ) public {
        vm.assume(uint8(confirmations) > 1);

        vm.assume(solver != bytes32(0));
        vm.assume(orderId != bytes32(0));
        vm.assume(caller != address(0));

        // We need to wrap to the Bitcoin block.
        vm.warp(BLOCK_TIME);
        bytes32 bitcoinOracleBytes32 = bytes32(uint256(uint160(address(bitcoinOracle))));
        MandateOutput memory output = MandateOutput({
            oracle: bitcoinOracleBytes32,
            settler: bitcoinOracleBytes32,
            token: bytes32(
                bytes.concat(hex"000000000000000000000000BC0000000000000000000000000000000000", confirmations, UTXO_TYPE)
            ),
            recipient: bytes32(PHASH),
            amount: SATS_AMOUNT,
            chainId: uint32(block.chainid),
            call: hex"",
            context: hex""
        });

        uint256 collateralAmount = output.amount * multiplier;
        token.mint(caller, collateralAmount);
        vm.prank(caller);
        token.approve(address(bitcoinOracle), collateralAmount);

        vm.prank(caller);
        bitcoinOracle.claim(solver, orderId, output);

        BtcTxProof memory inclusionProof = BtcTxProof({
            blockHeader: BLOCK_HEADER,
            txId: TX_ID,
            txIndex: TX_INDEX,
            txMerkleProof: TX_MERKLE_PROOF,
            rawTx: RAW_TX
        });

        vm.expectRevert(
            abi.encodeWithSignature("TooFewConfirmations(uint256,uint256)", 1, uint256(uint8(confirmations)))
        );
        bitcoinOracle.verify(orderId, output, BLOCK_HEIGHT, inclusionProof, TX_OUTPUT_INDEX);
    }

    function _getBlockHashFromHeader(
        bytes calldata blockHeader
    ) public pure returns (bytes32 blockHash) {
        blockHash = BtcProof.getBlockHash(blockHeader);
    }

    function _getPreviousBlockHashFromHeader(
        bytes calldata blockHeader
    ) public pure returns (bytes32 previousBlockHash) {
        previousBlockHash = bytes32(Endian.reverse256(uint256(bytes32(blockHeader[4:36]))));
    }
}
