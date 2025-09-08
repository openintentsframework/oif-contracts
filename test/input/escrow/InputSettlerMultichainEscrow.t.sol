// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { InputSettlerMultichainEscrow } from "../../../src/input/escrow/InputSettlerMultichainEscrow.sol";
import { MandateOutput, MandateOutputType } from "../../../src/input/types/MandateOutputType.sol";
import {
    MultichainOrderComponent,
    MultichainOrderComponentType
} from "../../../src/input/types/MultichainOrderComponentType.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";

import { AlwaysYesOracle } from "../../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { InputSettlerMultichainEscrowTestBase } from "./InputSettlerMultichainEscrow.base.t.sol";

contract InputSettlerMultichainEscrowTest is InputSettlerMultichainEscrowTestBase {
    using LibAddress for address;

    event Transfer(address from, address to, uint256 amount);
    event Transfer(address by, address from, address to, uint256 id, uint256 amount);
    event NextGovernanceFee(uint64 nextGovernanceFee, uint64 nextGovernanceFeeTime);
    event GovernanceFeeChanged(uint64 oldGovernanceFee, uint64 newGovernanceFee);

    uint64 constant GOVERNANCE_FEE_CHANGE_DELAY = 7 days;
    uint64 constant MAX_GOVERNANCE_FEE = 10 ** 18 * 0.05; // 10%

    address owner;

    // This test works slightly differently to other tests. We will be solving the entirety of the test, then opening
    // and finalising the test, rolling back the chain, and doing it again. This is to showcase that the funds can be
    // claimed on different chains.
    /// forge-config: default.isolate = true
    function test_finalise_self_2_inputs() public {
        // -- Set Up --//

        uint256 amount = 1e18 / 10;
        token.mint(swapper, amount);
        anotherToken.mint(swapper, amount);
        vm.prank(swapper);
        token.approve(address(inputSettlerMultichainEscrow), type(uint256).max);
        vm.prank(swapper);
        anotherToken.approve(address(inputSettlerMultichainEscrow), type(uint256).max);

        token.mint(solver, amount);
        vm.prank(solver);
        token.approve(address(outputSettlerSimple), type(uint256).max);

        uint256[2][] memory inputs0 = new uint256[2][](1);
        uint256[2][] memory inputs1 = new uint256[2][](1);
        inputs0[0] = [uint256(address(token).toIdentifier()), amount];
        inputs1[0] = [uint256(address(anotherToken).toIdentifier()), amount];

        // Get the additional chain input hashes. Note that we need the other chain's input.
        bytes32[] memory additionalChains0 = new bytes32[](1);
        additionalChains0[0] = keccak256(abi.encodePacked(uint256(3), inputs1));
        bytes32[] memory additionalChains1 = new bytes32[](1);
        additionalChains1[0] = keccak256(abi.encodePacked(uint256(0), inputs0));

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerSimple).toIdentifier(),
            oracle: address(wormholeOracle).toIdentifier(),
            chainId: 3,
            token: address(token).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            call: hex"",
            context: hex""
        });
        MultichainOrderComponent memory order = MultichainOrderComponent({
            user: address(swapper),
            nonce: 0,
            chainIdField: 0, // Selected index 0 chain.
            chainIndex: 0,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            localOracle: address(wormholeOracle),
            inputs: new uint256[2][](0), // Shall be replaced before execution
            outputs: outputs,
            additionalChains: new bytes32[](0) // Shall be replaced before execution
         });

        // Check that both orders have the same chainId
        vm.chainId(0);
        order.chainIdField = 0;
        order.chainIndex = 0;
        order.inputs = inputs0;
        order.additionalChains = additionalChains0;
        bytes32 orderId = InputSettlerMultichainEscrow(inputSettlerMultichainEscrow).orderIdentifier(order);
        vm.chainId(3);
        order.chainIdField = 3;
        order.chainIndex = 1;
        order.inputs = inputs1;
        order.additionalChains = additionalChains1;
        bytes32 orderId1 = InputSettlerMultichainEscrow(inputSettlerMultichainEscrow).orderIdentifier(order);
        assertEq(orderId, orderId1, "OrderId mismatch");

        // -- Begin Swap -- //
        // Fill swap
        vm.chainId(3);
        order.chainIdField = 3;
        order.chainIndex = 1;
        order.inputs = inputs1;
        order.additionalChains = additionalChains1;

        bytes memory outputToFill = getOutputToFillFromMandateOutput(order.fillDeadline, order.outputs[0]);
        vm.prank(solver);
        outputSettlerSimple.fill(orderId, outputToFill, abi.encode(solver));

        assertEq(token.balanceOf(solver), 0);

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solver.toIdentifier(), orderId, uint32(block.timestamp), outputs[0]
        );

        bytes memory expectedMessageEmitted = this.encodeMessage(outputs[0].settler, payloads);

        // Submit fill to wormhole
        wormholeOracle.submit(address(outputSettlerSimple), payloads);
        bytes memory vaa = makeValidVAA(uint16(3), address(wormholeOracle).toIdentifier(), expectedMessageEmitted);

        wormholeOracle.receiveMessage(vaa);

        bytes32[] memory solvers = new bytes32[](1);
        solvers[0] = solver.toIdentifier();
        // Open Order & finalise
        uint256 snapshotId = vm.snapshot();

        vm.chainId(0);
        order.chainIdField = 0;
        order.chainIndex = 0;
        order.inputs = inputs0;
        order.additionalChains = additionalChains0;
        vm.prank(swapper);
        InputSettlerMultichainEscrow(inputSettlerMultichainEscrow).open(order);

        assertEq(anotherToken.balanceOf(solver), 0);
        assertEq(anotherToken.balanceOf(inputSettlerMultichainEscrow), 0);
        assertEq(token.balanceOf(solver), 0);
        assertEq(token.balanceOf(inputSettlerMultichainEscrow), inputs0[0][1]);

        vm.prank(solver);

        {
            uint32[] memory timestamps = new uint32[](1);
            timestamps[0] = uint32(block.timestamp);
            InputSettlerMultichainEscrow(inputSettlerMultichainEscrow).finalise(
                order, timestamps, solvers, solver.toIdentifier(), hex""
            );
        }

        // Validate that we received input 0.
        assertEq(anotherToken.balanceOf(solver), 0);
        assertEq(anotherToken.balanceOf(inputSettlerMultichainEscrow), 0);
        assertEq(token.balanceOf(solver), inputs0[0][1]);
        assertEq(token.balanceOf(inputSettlerMultichainEscrow), 0);

        vm.revertTo(snapshotId);
        vm.chainId(3);
        order.chainIdField = 3;
        order.chainIndex = 1;
        order.inputs = inputs1;
        order.additionalChains = additionalChains1;
        vm.prank(swapper);
        InputSettlerMultichainEscrow(inputSettlerMultichainEscrow).open(order);

        assertEq(token.balanceOf(solver), 0);
        assertEq(token.balanceOf(inputSettlerMultichainEscrow), 0);
        assertEq(anotherToken.balanceOf(solver), 0);
        assertEq(anotherToken.balanceOf(inputSettlerMultichainEscrow), inputs1[0][1]);

        vm.prank(solver);

        {
            uint32[] memory timestamps = new uint32[](1);
            timestamps[0] = uint32(block.timestamp);
            InputSettlerMultichainEscrow(inputSettlerMultichainEscrow).finalise(
                order, timestamps, solvers, solver.toIdentifier(), hex""
            );
        }

        // Validate that we received input 1.
        assertEq(token.balanceOf(solver), 0);
        assertEq(token.balanceOf(inputSettlerMultichainEscrow), 0);
        assertEq(anotherToken.balanceOf(solver), inputs1[0][1]);
        assertEq(anotherToken.balanceOf(inputSettlerMultichainEscrow), 0);
    }
}
