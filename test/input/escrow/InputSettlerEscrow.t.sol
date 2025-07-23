// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { InputSettlerEscrow } from "../../../src/input/escrow/InputSettlerEscrow.sol";
import { MandateOutput, MandateOutputType } from "../../../src/input/types/MandateOutputType.sol";
import { StandardOrder } from "../../../src/input/types/StandardOrderType.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";

import { IInputSettlerEscrowHarness, InputSettlerEscrowTestBase } from "./InputSettlerEscrow.base.t.sol";

contract InputSettlerEscrowTest is InputSettlerEscrowTestBase {
    struct OrderFulfillmentDescription {
        uint32 timestamp;
        MandateOutput MandateOutput;
    }

    /// forge-config: default.isolate = true
    function test_validate_fills_one_solver_gas() external {
        OrderFulfillmentDescription[] memory fds = new OrderFulfillmentDescription[](2);
        fds[0] = OrderFulfillmentDescription({
            timestamp: 10001,
            MandateOutput: MandateOutput({
                oracle: keccak256(bytes("remoteOracle")),
                settler: keccak256(bytes("outputSettler")),
                chainId: 123,
                token: keccak256(bytes("token")),
                amount: 10 ** 18,
                recipient: keccak256(bytes("recipient")),
                call: hex"",
                context: hex""
            })
        });
        fds[1] = OrderFulfillmentDescription({
            timestamp: 10001,
            MandateOutput: MandateOutput({
                oracle: keccak256(bytes("remoteOracle")),
                settler: keccak256(bytes("outputSettler")),
                chainId: 321,
                token: keccak256(bytes("token1")),
                amount: 10 ** 12,
                recipient: keccak256(bytes("recipient")),
                call: hex"",
                context: hex""
            })
        });

        test_validate_fills_one_solver(keccak256(bytes("solverIdentifier")), keccak256(bytes("orderId")), fds);
    }

    function test_validate_fills_one_solver(
        bytes32 solverIdentifier,
        bytes32 orderId,
        OrderFulfillmentDescription[] memory orderFulfillmentDescription
    ) public {
        vm.assume(orderFulfillmentDescription.length > 0);

        bytes memory expectedProofPayload = hex"";
        uint32[] memory timestamps = new uint32[](orderFulfillmentDescription.length);
        MandateOutput[] memory MandateOutputs = new MandateOutput[](orderFulfillmentDescription.length);
        bytes32[] memory solvers = new bytes32[](orderFulfillmentDescription.length);
        for (uint256 i; i < orderFulfillmentDescription.length; ++i) {
            solvers[i] = solverIdentifier;
            timestamps[i] = orderFulfillmentDescription[i].timestamp;
            MandateOutputs[i] = orderFulfillmentDescription[i].MandateOutput;

            expectedProofPayload = abi.encodePacked(
                expectedProofPayload,
                MandateOutputs[i].chainId,
                MandateOutputs[i].oracle,
                MandateOutputs[i].settler,
                keccak256(
                    MandateOutputEncodingLib.encodeFillDescriptionMemory(
                        solverIdentifier, orderId, timestamps[i], MandateOutputs[i]
                    )
                )
            );
        }
        _validProofSeries[expectedProofPayload] = true;

        StandardOrder memory order = StandardOrder({
            user: address(0), // not used
            nonce: 0, // not used
            originChainId: 0, // not used.
            expires: 0, // not used
            fillDeadline: type(uint32).max,
            localOracle: address(this),
            inputs: new uint256[2][](0), // not used
            outputs: MandateOutputs
        });

        IInputSettlerEscrowHarness(inputSettlerEscrow).validateFills(
            order.fillDeadline, order.localOracle, order.outputs, orderId, solvers, timestamps
        );
        vm.snapshotGasLastCall("inputSettler", "escrowValidate2Fills");
    }

    struct OrderFulfillmentDescriptionWithSolver {
        uint32 timestamp;
        bytes32 solver;
        MandateOutput MandateOutput;
    }

    /// forge-config: default.isolate = true
    function test_validate_fills_multiple_solvers_gas() external {
        OrderFulfillmentDescriptionWithSolver[] memory fds = new OrderFulfillmentDescriptionWithSolver[](2);
        fds[0] = OrderFulfillmentDescriptionWithSolver({
            timestamp: 10001,
            solver: keccak256(bytes("solverIdentifier1")),
            MandateOutput: MandateOutput({
                oracle: keccak256(bytes("remoteOracle")),
                settler: keccak256(bytes("outputSettler")),
                chainId: 123,
                token: keccak256(bytes("token")),
                amount: 10 ** 18,
                recipient: keccak256(bytes("recipient")),
                call: hex"",
                context: hex""
            })
        });
        fds[1] = OrderFulfillmentDescriptionWithSolver({
            timestamp: 10001,
            solver: keccak256(bytes("solverIdentifier2")),
            MandateOutput: MandateOutput({
                oracle: keccak256(bytes("remoteOracle")),
                settler: keccak256(bytes("outputSettler")),
                chainId: 321,
                token: keccak256(bytes("token1")),
                amount: 10 ** 12,
                recipient: keccak256(bytes("recipient")),
                call: hex"",
                context: hex""
            })
        });

        test_validate_fills_multiple_solvers(keccak256(bytes("orderId")), fds);
    }

    function test_validate_fills_multiple_solvers(
        bytes32 orderId,
        OrderFulfillmentDescriptionWithSolver[] memory orderFulfillmentDescriptionWithSolver
    ) public {
        vm.assume(orderFulfillmentDescriptionWithSolver.length > 0);

        bytes memory expectedProofPayload = hex"";
        uint32[] memory timestamps = new uint32[](orderFulfillmentDescriptionWithSolver.length);
        MandateOutput[] memory MandateOutputs = new MandateOutput[](orderFulfillmentDescriptionWithSolver.length);
        bytes32[] memory solvers = new bytes32[](orderFulfillmentDescriptionWithSolver.length);
        for (uint256 i; i < orderFulfillmentDescriptionWithSolver.length; ++i) {
            timestamps[i] = orderFulfillmentDescriptionWithSolver[i].timestamp;
            MandateOutputs[i] = orderFulfillmentDescriptionWithSolver[i].MandateOutput;
            solvers[i] = orderFulfillmentDescriptionWithSolver[i].solver;

            expectedProofPayload = abi.encodePacked(
                expectedProofPayload,
                MandateOutputs[i].chainId,
                MandateOutputs[i].oracle,
                MandateOutputs[i].settler,
                keccak256(
                    MandateOutputEncodingLib.encodeFillDescriptionMemory(
                        solvers[i], orderId, timestamps[i], MandateOutputs[i]
                    )
                )
            );
        }
        _validProofSeries[expectedProofPayload] = true;

        StandardOrder memory order = StandardOrder({
            user: address(0), // not used
            nonce: 0, // not used
            originChainId: 0, // not used.
            expires: 0, // not used
            fillDeadline: type(uint32).max,
            localOracle: address(this),
            inputs: new uint256[2][](0), // not used
            outputs: MandateOutputs
        });

        IInputSettlerEscrowHarness(inputSettlerEscrow).validateFills(
            order.fillDeadline, order.localOracle, order.outputs, orderId, solvers, timestamps
        );
        vm.snapshotGasLastCall("inputSettler", "escrowValidate2FillsMultipleSolvers");
    }

    /// forge-config: default.isolate = true
    function test_open_gas() external {
        test_open(10000, 10 ** 18, makeAddr("user"));
    }

    function test_open(uint32 fillDeadline, uint128 amount, address user) public {
        vm.assume(fillDeadline > block.timestamp);
        vm.assume(token.balanceOf(user) == 0);
        vm.assume(user != inputSettlerEscrow);

        token.mint(user, amount);
        vm.prank(user);
        token.approve(inputSettlerEscrow, amount);

        MandateOutput[] memory outputs = new MandateOutput[](0);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: fillDeadline,
            localOracle: address(0),
            inputs: inputs,
            outputs: outputs
        });

        assertEq(token.balanceOf(address(user)), amount);

        vm.prank(user);
        IInputSettlerEscrowHarness(inputSettlerEscrow).open(order);
        vm.snapshotGasLastCall("inputSettler", "escrowOpen");

        assertEq(token.balanceOf(address(user)), 0);
        assertEq(token.balanceOf(inputSettlerEscrow), amount);
    }

    ///// forge-config: default.isolate = true
    // function test_open_for_gas() external {
    //     test_open_for(10 ** 18, 251251);
    // }

    // TODO: reenable
    // function test_open_for(uint128 amountMint, uint256 nonce) public {
    //     token.mint(swapper, amountMint);

    //     uint256 amount = token.balanceOf(swapper);

    //     // Permit2 has default infinite allowance. (Solady erc20)
    //     // vm.prank(swapper);
    //     // token.approve(address(permit2), amount);

    //     MandateOutput[] memory outputs = new MandateOutput[](0);

    //     uint256[2][] memory inputs = new uint256[2][](1);
    //     inputs[0] = [uint256(uint160(address(token))), amount];

    //     StandardOrder memory order = StandardOrder({
    //         user: swapper,
    //         nonce: nonce,
    //         originChainId: block.chainid,
    //         expires: type(uint32).max,
    //         fillDeadline: type(uint32).max,
    //         localOracle: address(0),
    //         inputs: inputs,
    //         outputs: outputs
    //     });

    //     bytes memory signature = getPermit2Signature(swapperPrivateKey, order);

    //     assertEq(token.balanceOf(address(swapper)), amount);

    //     vm.prank(swapper);
    //     IInputSettlerEscrowHarness(inputSettlerEscrow).openFor(order, signature, hex"");
    //     vm.snapshotGasLastCall("inputSettler", "escrowOpenFor");

    //     assertEq(token.balanceOf(address(swapper)), 0);
    //     assertEq(token.balanceOf(inputSettlerEscrow), amount);
    // }

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
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(alwaysYesOracle))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
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
        IInputSettlerEscrowHarness(inputSettlerEscrow).open(order);

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = bytes32(uint256(uint160((solver))));

        // Other callers are disallowed:
        vm.prank(non_solver);

        vm.expectRevert(abi.encodeWithSignature("NotOrderOwner()"));
        IInputSettlerEscrowHarness(inputSettlerEscrow).finalise(
            order, timestamps, solvers, bytes32(uint256(uint160((solver)))), hex""
        );

        assertEq(token.balanceOf(solver), 0);

        bytes32 orderId = IInputSettlerEscrowHarness(inputSettlerEscrow).orderIdentifier(order);
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            bytes32(uint256(uint160((solver)))), orderId, uint32(block.timestamp), outputs[0]
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
        IInputSettlerEscrowHarness(inputSettlerEscrow).finalise(
            order, timestamps, solvers, bytes32(uint256(uint160(solver))), hex""
        );
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
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(alwaysYesOracle))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
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
        IInputSettlerEscrowHarness(inputSettlerEscrow).open(order);

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = filledAt;

        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = bytes32(uint256(uint160(solver)));

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("FilledTooLate(uint32,uint32)", fillDeadline, filledAt));
        IInputSettlerEscrowHarness(inputSettlerEscrow).finalise(
            order, timestamps, solvers, bytes32(uint256(uint160(solver))), hex""
        );
    }

    /// forge-config: default.isolate = true
    function test_finalise_signature_gas() external {
        test_finalise_signature(makeAddr("destination"));
    }

    function test_finalise_signature(
        address destination
    ) public {
        vm.assume(token.balanceOf(destination) == 0);

        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(alwaysYesOracle))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
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
        IInputSettlerEscrowHarness(inputSettlerEscrow).open(order);

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        bytes32 orderId = IInputSettlerEscrowHarness(inputSettlerEscrow).orderIdentifier(order);
        {
            bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
                bytes32(uint256(uint160((solver)))), orderId, uint32(block.timestamp), outputs[0]
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
        solvers[0] = bytes32(uint256(uint160((solver))));

        bytes memory orderOwnerSignature =
            this.getOrderOpenSignature(solverPrivateKey, orderId, bytes32(uint256(uint160((destination)))), hex"");

        IInputSettlerEscrowHarness(inputSettlerEscrow).finaliseWithSignature(
            order, timestamps, solvers, bytes32(uint256(uint160((destination)))), hex"", orderOwnerSignature
        );
        vm.snapshotGasLastCall("inputSettler", "escrowFinaliseWithSignature");

        assertEq(token.balanceOf(destination), amount);
    }
}
