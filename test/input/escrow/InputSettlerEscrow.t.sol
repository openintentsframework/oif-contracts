// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { InputSettlerEscrow } from "../../../src/input/escrow/InputSettlerEscrow.sol";
import { MandateOutput } from "../../../src/input/types/MandateOutputType.sol";
import { StandardOrder } from "../../../src/input/types/StandardOrderType.sol";

import { IInputSettlerEscrow } from "../../../src/interfaces/IInputSettlerEscrow.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";

import { InputSettlerEscrowTestBase } from "./InputSettlerEscrow.base.t.sol";

contract InputSettlerEscrowTest is InputSettlerEscrowTestBase {
    using LibAddress for address;
    using LibAddress for bytes32;

    /// forge-config: default.isolate = true
    function test_open_gas() external {
        test_open(10000, 10 ** 18, makeAddr("user"));
    }

    function test_open(uint32 expires, uint128 amount, address user) public returns (StandardOrder memory order) {
        vm.assume(expires < type(uint32).max);
        vm.assume(expires > block.timestamp);
        vm.assume(token.balanceOf(user) == 0);
        vm.assume(user != inputSettlerEscrow);

        token.mint(user, amount);
        vm.prank(user);
        token.approve(inputSettlerEscrow, amount);

        MandateOutput[] memory outputs = new MandateOutput[](0);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: expires,
            fillDeadline: expires,
            localOracle: address(0),
            inputs: inputs,
            outputs: outputs
        });

        assertEq(token.balanceOf(address(user)), amount);

        vm.prank(user);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);
        vm.snapshotGasLastCall("inputSettler", "escrowOpen");

        assertEq(token.balanceOf(address(user)), 0);
        assertEq(token.balanceOf(inputSettlerEscrow), amount);
    }

    /// forge-config: default.isolate = true
    function test_open_for_gas() external {
        test_open_for(10 ** 18, 251251);
    }

    function test_open_for(uint128 amountMint, uint256 nonce) public {
        token.mint(swapper, amountMint);

        uint256 amount = token.balanceOf(swapper);

        // Permit2 has default infinite allowance. (Solady erc20)
        // vm.prank(swapper);
        // token.approve(address(permit2), amount);

        MandateOutput[] memory outputs = new MandateOutput[](0);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: nonce,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            localOracle: address(0),
            inputs: inputs,
            outputs: outputs
        });

        bytes memory signature = getPermit2Signature(swapperPrivateKey, order);

        assertEq(token.balanceOf(address(swapper)), amount);

        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).openFor(order, signature, hex"");
        vm.snapshotGasLastCall("inputSettler", "escrowOpenFor");

        assertEq(token.balanceOf(address(swapper)), 0);
        assertEq(token.balanceOf(inputSettlerEscrow), amount);
    }

    function test_refund(uint32 expires, uint128 amount, address user) public {
        vm.assume(amount < type(uint128).max);
        StandardOrder memory order = test_open(expires, amount, user);
        // Wrap into the future of the expiry.
        vm.warp(order.expires + 1);

        bytes32 orderId = InputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);

        // Check order status:
        InputSettlerEscrow.OrderStatus status = InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId);
        assertEq(uint8(status), uint8(InputSettlerEscrow.OrderStatus.Deposited));

        // State
        uint256 amountBeforeRefund = token.balanceOf(address(order.user));

        vm.expectEmit();
        emit InputSettlerEscrow.Refunded(orderId);

        // Do the refund
        InputSettlerEscrow(inputSettlerEscrow).refund(order);
        vm.snapshotGasLastCall("inputSettler", "escrowRefund");

        // State
        assertEq(token.balanceOf(address(order.user)), amountBeforeRefund + amount);
        assertEq(token.balanceOf(inputSettlerEscrow), 0);

        status = InputSettlerEscrow(inputSettlerEscrow).orderStatus(orderId);
        assertEq(uint8(status), uint8(InputSettlerEscrow.OrderStatus.Refunded));
    }

    // -- Larger Integration tests -- //

    /// forge-config: default.isolate = true
    function test_finalise_gas() public {
        test_finalise(makeAddr("non_solver"));
    }

    function test_finalise(
        address non_solver
    ) public {
        vm.assume(non_solver != solver);

        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            localOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

        // Deposit into the escrow
        vm.prank(swapper);
        token.approve(inputSettlerEscrow, amount);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = solver.toIdentifier();

        // Other callers are disallowed:
        vm.prank(non_solver);

        vm.expectRevert(abi.encodeWithSignature("UnexpectedCaller(bytes32)", solvers[0]));
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, timestamps, solvers, solver.toIdentifier(), hex"");

        assertEq(token.balanceOf(solver), 0);

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solver.toIdentifier(), orderId, uint32(block.timestamp), outputs[0]
        );
        bytes32 payloadHash = keccak256(payload);

        vm.expectCall(
            address(alwaysYesOracle),
            abi.encodeWithSignature(
                "efficientRequireProven(bytes)",
                abi.encodePacked(
                    order.outputs[0].chainId, order.outputs[0].oracle, order.outputs[0].settler, payloadHash
                )
            )
        );

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, timestamps, solvers, solver.toIdentifier(), hex"");
        vm.snapshotGasLastCall("inputSettler", "EscrowFinalise");

        assertEq(token.balanceOf(solver), amount);
    }

    function test_revert_finalise_self_too_late(address non_solver, uint32 fillDeadline, uint32 filledAt) external {
        vm.assume(non_solver != solver);
        vm.assume(fillDeadline < filledAt);
        vm.assume(block.timestamp < fillDeadline);

        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: fillDeadline,
            localOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

        // Deposit into the escrow
        vm.prank(swapper);
        token.approve(inputSettlerEscrow, amount);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = filledAt;

        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = solver.toIdentifier();

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("FilledTooLate(uint32,uint32)", fillDeadline, filledAt));
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, timestamps, solvers, solver.toIdentifier(), hex"");
    }

    /// forge-config: default.isolate = true
    function test_finalise_signature_gas() external {
        test_finalise_signature(makeAddr("destination"));
    }

    function test_finalise_signature(
        address destination
    ) public {
        vm.assume(destination != address(0));
        vm.assume(token.balanceOf(destination) == 0);

        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: alwaysYesOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            localOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

        // Deposit into the escrow
        vm.prank(swapper);
        token.approve(inputSettlerEscrow, amount);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        {
            bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solver.toIdentifier(), orderId, uint32(block.timestamp), outputs[0]
            );
            bytes32 payloadHash = keccak256(payload);

            vm.expectCall(
                address(alwaysYesOracle),
                abi.encodeWithSignature(
                    "efficientRequireProven(bytes)",
                    abi.encodePacked(
                        order.outputs[0].chainId, order.outputs[0].oracle, order.outputs[0].settler, payloadHash
                    )
                )
            );
        }

        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = solver.toIdentifier();

        bytes memory orderOwnerSignature =
            this.getOrderOpenSignature(solverPrivateKey, orderId, destination.toIdentifier(), hex"");

        IInputSettlerEscrow(inputSettlerEscrow).finaliseWithSignature(
            order, timestamps, solvers, destination.toIdentifier(), hex"", orderOwnerSignature
        );
        vm.snapshotGasLastCall("inputSettler", "escrowFinaliseWithSignature");

        assertEq(token.balanceOf(destination), amount);
    }
}
