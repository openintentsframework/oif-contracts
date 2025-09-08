// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { InputSettlerMultichainCompact } from "../../../src/input/compact/InputSettlerMultichainCompact.sol";
import { MandateOutput, MandateOutputType } from "../../../src/input/types/MandateOutputType.sol";
import {
    MultichainOrderComponent,
    MultichainOrderComponentType
} from "../../../src/input/types/MultichainOrderComponentType.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";

import { AlwaysYesOracle } from "../../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { EIP712, InputSettlerMultichainCompactTestBase } from "./InputSettlerMultichainCompact.base.t.sol";

contract InputSettlerMultichainCompactTest is InputSettlerMultichainCompactTestBase {
    using LibAddress for address;
    using LibAddress for bytes32;

    event Transfer(address from, address to, uint256 amount);
    event Transfer(address by, address from, address to, uint256 id, uint256 amount);

    event Finalised(bytes32 indexed orderId, bytes32 solver, bytes32 destination);

    uint64 constant GOVERNANCE_FEE_CHANGE_DELAY = 7 days;
    uint64 constant MAX_GOVERNANCE_FEE = 10 ** 18 * 0.05; // 10%

    address owner;

    // This test works slightly differently to other tests. We will be solving the entirety of the test, then opening
    // and finalising the test, rolling back the chain, and doing it again. This is to showcase that the funds can be
    // claimed on different chains.
    /// forge-config: default.isolate = true
    function test_finalise_self_2_inputs() public {
        // -- Set Up --//

        token.mint(swapper, 1e18 / 10);
        anotherToken.mint(swapper, 1e18 / 10);
        vm.prank(swapper);
        token.approve(address(theCompact), type(uint256).max);
        vm.prank(swapper);
        anotherToken.approve(address(theCompact), type(uint256).max);

        token.mint(solver, 1e18 / 10);

        vm.prank(solver);
        token.approve(address(outputSettlerSimple), type(uint256).max);

        MultichainOrderComponent memory order1;
        MultichainOrderComponent memory order3;
        {
            uint256[2][] memory inputs1 = new uint256[2][](1);
            uint256[2][] memory inputs3 = new uint256[2][](1);
            {
                vm.prank(swapper);
                uint256 tokenId0 = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, 1e18 / 10, swapper);
                inputs1[0] = [tokenId0, 1e18 / 10];
            }
            {
                vm.prank(swapper);
                uint256 tokenId1 =
                    theCompact.depositERC20(address(anotherToken), alwaysOkAllocatorLockTag, 1e18 / 10, swapper);
                inputs3[0] = [tokenId1, 1e18 / 10];
            }
            MandateOutput[] memory outputs = new MandateOutput[](1);
            outputs[0] = MandateOutput({
                settler: address(outputSettlerSimple).toIdentifier(),
                oracle: address(wormholeOracle).toIdentifier(),
                chainId: 3,
                token: address(token).toIdentifier(),
                amount: 1e18 / 10,
                recipient: swapper.toIdentifier(),
                call: hex"",
                context: hex""
            });

            // Get the additional chain input hashes. Note that we need the other chain's input.
            bytes32[] memory additionalChains1 = new bytes32[](1);
            additionalChains1[0] = getElementHash(
                InputSettlerMultichainCompactTestBase.Element(inputSettlerMultichainCompact, 3, uintsToLocks(inputs3)),
                witnessHash(type(uint32).max, address(wormholeOracle), outputs)
            );
            bytes32[] memory additionalChains3 = new bytes32[](1);
            additionalChains3[0] = getElementHash(
                InputSettlerMultichainCompactTestBase.Element(inputSettlerMultichainCompact, 1, uintsToLocks(inputs1)),
                witnessHash(type(uint32).max, address(wormholeOracle), outputs)
            );

            order1 = MultichainOrderComponent({
                user: address(swapper),
                nonce: 0,
                chainIdField: 1,
                chainIndex: 0,
                fillDeadline: type(uint32).max,
                expires: type(uint32).max,
                localOracle: address(wormholeOracle),
                inputs: inputs1,
                outputs: outputs,
                additionalChains: additionalChains1
            });

            order3 = MultichainOrderComponent({
                user: address(swapper),
                nonce: 0,
                chainIdField: 1,
                chainIndex: 1,
                fillDeadline: type(uint32).max,
                expires: type(uint32).max,
                localOracle: address(wormholeOracle),
                inputs: inputs3,
                outputs: outputs,
                additionalChains: additionalChains3
            });
        }
        // Check that both orders have the same chainId
        {
            vm.chainId(1);
            bytes32 orderId1 = InputSettlerMultichainCompact(inputSettlerMultichainCompact).orderIdentifier(order1);
            vm.chainId(3);
            bytes32 orderId3 = InputSettlerMultichainCompact(inputSettlerMultichainCompact).orderIdentifier(order3);
            assertEq(orderId1, orderId3, "OrderId mismatch");
        }

        // -- Begin Swap -- //
        // Fill swap
        {
            vm.chainId(3);
            bytes32 orderId3 = InputSettlerMultichainCompact(inputSettlerMultichainCompact).orderIdentifier(order3);
            bytes memory outputToFill = getOutputToFillFromMandateOutput(order1.fillDeadline, order1.outputs[0]);
            vm.prank(solver);
            outputSettlerSimple.fill(orderId3, outputToFill, abi.encode(solver));
        }

        assertEq(token.balanceOf(solver), 0);

        {
            bytes[] memory payloads = new bytes[](1);
            bytes32 orderId3 = InputSettlerMultichainCompact(inputSettlerMultichainCompact).orderIdentifier(order3);
            payloads[0] = MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solver.toIdentifier(), orderId3, uint32(block.timestamp), order1.outputs[0]
            );

            bytes memory expectedMessageEmitted = this.encodeMessage(order1.outputs[0].settler, payloads);

            // Submit fill to wormhole
            wormholeOracle.submit(address(outputSettlerSimple), payloads);
            bytes memory vaa = makeValidVAA(uint16(3), address(wormholeOracle).toIdentifier(), expectedMessageEmitted);

            wormholeOracle.receiveMessage(vaa);
        }
        // Open Order & finalise
        uint256 snapshotId = vm.snapshot();

        vm.chainId(1);
        bytes memory signatures;
        {
            Element[] memory elements = new Element[](2);
            elements[0] = Element({
                arbiter: inputSettlerMultichainCompact,
                chainId: 1,
                commitments: uintsToLocks(order1.inputs)
            });
            elements[1] = Element({
                arbiter: inputSettlerMultichainCompact,
                chainId: 3,
                commitments: uintsToLocks(order3.inputs)
            });
            // (Sponsor signature but stored in initiated variable for stack)
            signatures = getCompactMultichainWitnessSignature(
                EIP712(address(theCompact)).DOMAIN_SEPARATOR(),
                swapperPrivateKey,
                swapper,
                0,
                type(uint32).max,
                elements,
                witnessHash(type(uint32).max, address(wormholeOracle), order1.outputs)
            );
            bytes memory allocatorSignature = getCompactMultichainWitnessSignature(
                EIP712(address(theCompact)).DOMAIN_SEPARATOR(),
                allocatorPrivateKey,
                swapper,
                0,
                type(uint32).max,
                elements,
                witnessHash(type(uint32).max, address(wormholeOracle), order1.outputs)
            );
            signatures = abi.encode(signatures, allocatorSignature);
        }

        assertEq(token.balanceOf(address(theCompact)), order1.inputs[0][1]);
        assertEq(token.balanceOf(solver), 0);
        assertEq(anotherToken.balanceOf(address(theCompact)), order3.inputs[0][1]);
        assertEq(anotherToken.balanceOf(solver), 0);

        {
            vm.expectEmit();
            emit Finalised(
                InputSettlerMultichainCompact(inputSettlerMultichainCompact).orderIdentifier(order1),
                solver.toIdentifier(),
                solver.toIdentifier()
            );
            uint32[] memory timestamps = new uint32[](1);
            timestamps[0] = uint32(block.timestamp);
            bytes32[] memory solvers = new bytes32[](1);
            solvers[0] = solver.toIdentifier();
            vm.prank(solver);
            InputSettlerMultichainCompact(inputSettlerMultichainCompact).finalise(
                order1, signatures, timestamps, solvers, solver.toIdentifier(), hex""
            );
        }

        // Validate that we received input 0.
        assertEq(token.balanceOf(address(theCompact)), 0);
        assertEq(token.balanceOf(solver), order1.inputs[0][1]);
        assertEq(anotherToken.balanceOf(address(theCompact)), order3.inputs[0][1]);
        assertEq(anotherToken.balanceOf(solver), 0);

        vm.revertTo(snapshotId);
        vm.chainId(3);

        assertEq(token.balanceOf(address(theCompact)), order1.inputs[0][1]);
        assertEq(token.balanceOf(solver), 0);
        assertEq(anotherToken.balanceOf(address(theCompact)), order3.inputs[0][1]);
        assertEq(anotherToken.balanceOf(solver), 0);

        {
            vm.expectEmit();
            emit Finalised(
                InputSettlerMultichainCompact(inputSettlerMultichainCompact).orderIdentifier(order3),
                solver.toIdentifier(),
                solver.toIdentifier()
            );
            uint32[] memory timestamps = new uint32[](1);
            timestamps[0] = uint32(block.timestamp);
            bytes32[] memory solvers = new bytes32[](1);
            solvers[0] = solver.toIdentifier();
            vm.prank(solver);
            InputSettlerMultichainCompact(inputSettlerMultichainCompact).finalise(
                order3, signatures, timestamps, solvers, solver.toIdentifier(), hex""
            );
        }

        // Validate that we received input 1.
        assertEq(token.balanceOf(address(theCompact)), order1.inputs[0][1]);
        assertEq(token.balanceOf(solver), 0);
        assertEq(anotherToken.balanceOf(address(theCompact)), 0);
        assertEq(anotherToken.balanceOf(solver), order3.inputs[0][1]);

        // Test opening with signature
        vm.revertTo(snapshotId);
        vm.chainId(3);

        bytes32 destination = keccak256(bytes("destination")).fromIdentifier().toIdentifier();
        {
            bytes memory openSignature = this.getOrderOpenSignature(
                solverPrivateKey,
                InputSettlerMultichainCompact(inputSettlerMultichainCompact).orderIdentifier(order3),
                destination,
                hex""
            );
            uint32[] memory timestamps = new uint32[](1);
            timestamps[0] = uint32(block.timestamp);
            bytes32[] memory solvers = new bytes32[](1);
            solvers[0] = solver.toIdentifier();
            vm.prank(swapper);
            InputSettlerMultichainCompact(inputSettlerMultichainCompact).finaliseWithSignature(
                order3, signatures, timestamps, solvers, destination, hex"", openSignature
            );
        }

        assertEq(token.balanceOf(solver), 0);
        assertEq(token.balanceOf(address(theCompact)), order1.inputs[0][1]);
        assertEq(anotherToken.balanceOf(destination.fromIdentifier()), order3.inputs[0][1]);
        assertEq(anotherToken.balanceOf(inputSettlerMultichainCompact), 0);
    }
}
