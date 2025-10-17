// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { TheCompact } from "the-compact/src/TheCompact.sol";

import { MandateOutput, MandateOutputType } from "../../../src/input/types/MandateOutputType.sol";
import { StandardOrder, StandardOrderType } from "../../../src/input/types/StandardOrderType.sol";

import { InputSettlerBase } from "../../../src/input/InputSettlerBase.sol";
import { IInputSettlerCompact } from "../../../src/interfaces/IInputSettlerCompact.sol";
import { LibAddress } from "../../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { AlwaysYesOracle } from "../../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { InputSettlerCompactTestBase } from "./InputSettlerCompact.base.t.sol";

contract InputSettlerCompactTest is InputSettlerCompactTestBase {
    using LibAddress for address;

    event Transfer(address from, address to, uint256 amount);
    event Transfer(address by, address from, address to, uint256 id, uint256 amount);
    event CompactRegistered(address indexed sponsor, bytes32 claimHash, bytes32 typehash);
    event NextGovernanceFee(uint64 nextGovernanceFee, uint64 nextGovernanceFeeTime);
    event GovernanceFeeChanged(uint64 oldGovernanceFee, uint64 newGovernanceFee);

    uint64 constant GOVERNANCE_FEE_CHANGE_DELAY = 7 days;
    uint64 constant MAX_GOVERNANCE_FEE = 10 ** 18 * 0.05; // 10%

    address owner;

    // -- Larger Integration tests -- //

    /// forge-config: default.isolate = true
    function test_finalise_self_gas() external {
        test_finalise_self(makeAddr("non_solver"));
    }

    function test_finalise_self(
        address non_solver
    ) public {
        vm.assume(non_solver != solver);

        uint256 amount = 1e18 / 10;
        token.mint(swapper, amount);
        vm.prank(swapper);
        token.approve(address(theCompact), type(uint256).max);

        vm.prank(swapper);
        uint256 tokenId = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, amount, swapper);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [tokenId, amount];
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: address(alwaysYesOracle).toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

        // Make Compact
        uint256[2][] memory idsAndAmounts = new uint256[2][](1);
        idsAndAmounts[0] = [tokenId, amount];

        bytes memory sponsorSig = getCompactBatchWitnessSignature(
            swapperPrivateKey, inputSettlerCompact, swapper, 0, type(uint32).max, idsAndAmounts, witnessHash(order)
        );

        bytes memory signature = abi.encode(sponsorSig, hex"");

        bytes32 solverIdentifier = solver.toIdentifier();

        // Other callers are disallowed:
        vm.prank(non_solver);
        vm.expectRevert(abi.encodeWithSignature("NotOrderOwner()"));

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solverIdentifier, timestamp: uint32(block.timestamp) });
        IInputSettlerCompact(inputSettlerCompact).finalise(order, signature, solveParams, solverIdentifier, hex"");

        assertEq(token.balanceOf(solver), 0);

        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solverIdentifier,
            IInputSettlerCompact(inputSettlerCompact).orderIdentifier(order),
            uint32(block.timestamp),
            outputs[0]
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
        IInputSettlerCompact(inputSettlerCompact).finalise(order, signature, solveParams, solverIdentifier, hex"");
        vm.snapshotGasLastCall("inputSettler", "CompactFinaliseSelf");

        assertEq(token.balanceOf(solver), amount);
    }

    function test_revert_finalise_self_too_late(
        address non_solver,
        uint32 fillDeadline,
        uint32 filledAt
    ) external {
        vm.assume(non_solver != solver);
        vm.assume(fillDeadline < filledAt);

        uint256 amount = 1e18 / 10;

        token.mint(swapper, amount);
        vm.prank(swapper);
        token.approve(address(theCompact), type(uint256).max);

        vm.prank(swapper);
        uint256 tokenId = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, amount, swapper);

        address inputOracle = address(alwaysYesOracle);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [tokenId, amount];
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: inputOracle.toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: fillDeadline,
            expires: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

        // Make Compact
        uint256[2][] memory idsAndAmounts = new uint256[2][](1);
        idsAndAmounts[0] = [tokenId, amount];

        bytes memory sponsorSig = getCompactBatchWitnessSignature(
            swapperPrivateKey, inputSettlerCompact, swapper, 0, type(uint32).max, idsAndAmounts, witnessHash(order)
        );
        bytes memory allocatorSig = hex"";

        bytes memory signature = abi.encode(sponsorSig, allocatorSig);

        bytes32 solverIdentifier = solver.toIdentifier();

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solverIdentifier, timestamp: filledAt });

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("FilledTooLate(uint32,uint32)", fillDeadline, filledAt));
        IInputSettlerCompact(inputSettlerCompact).finalise(order, signature, solveParams, solverIdentifier, hex"");
    }

    /// forge-config: default.isolate = true
    function test_finalise_to_gas() external {
        test_finalise_to(makeAddr("non_solver"), makeAddr("destination"));
    }

    function test_finalise_to(
        address non_solver,
        address destination
    ) public {
        vm.assume(destination != inputSettlerCompact);
        vm.assume(destination != address(theCompact));
        vm.assume(destination != swapper);
        vm.assume(destination != address(0));
        vm.assume(token.balanceOf(destination) == 0);
        vm.assume(non_solver != solver);

        token.mint(swapper, 1e18);
        vm.prank(swapper);
        token.approve(address(theCompact), type(uint256).max);

        vm.prank(swapper);
        uint256 amount = 1e18 / 10;
        uint256 tokenId = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, amount, swapper);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [tokenId, amount];
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettlerCoin).toIdentifier(),
            oracle: address(alwaysYesOracle).toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            inputOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

        // Make Compact
        uint256[2][] memory idsAndAmounts = new uint256[2][](1);
        idsAndAmounts[0] = [tokenId, amount];

        bytes memory sponsorSig = getCompactBatchWitnessSignature(
            swapperPrivateKey, inputSettlerCompact, swapper, 0, type(uint32).max, idsAndAmounts, witnessHash(order)
        );

        bytes memory signature = abi.encode(sponsorSig, hex"");

        // Other callers are disallowed:

        vm.prank(non_solver);

        vm.expectRevert(abi.encodeWithSignature("NotOrderOwner()"));
        bytes32 solverIdentifier = solver.toIdentifier();
        bytes32 destinationIdentifier = destination.toIdentifier();
        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solverIdentifier, timestamp: uint32(block.timestamp) });
        IInputSettlerCompact(inputSettlerCompact).finalise(order, signature, solveParams, destinationIdentifier, hex"");

        assertEq(token.balanceOf(destination), 0);

        vm.prank(solver);
        IInputSettlerCompact(inputSettlerCompact).finalise(order, signature, solveParams, destinationIdentifier, hex"");
        vm.snapshotGasLastCall("inputSettler", "CompactFinaliseTo");

        assertEq(token.balanceOf(destination), amount);
    }

    /// forge-config: default.isolate = true
    function test_finalise_for_gas() external {
        test_finalise_for(makeAddr("non_solver"), makeAddr("destination"));
    }

    function test_finalise_for(
        address non_solver,
        address destination
    ) public {
        vm.assume(destination != inputSettlerCompact);
        vm.assume(destination != address(theCompact));
        vm.assume(destination != address(swapper));
        vm.assume(destination != address(solver));
        vm.assume(destination != address(0));
        vm.assume(non_solver != solver);

        token.mint(swapper, 1e18);
        vm.prank(swapper);
        token.approve(address(theCompact), type(uint256).max);

        vm.prank(swapper);
        uint256 amount = 1e18 / 10;
        uint256 tokenId = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, amount, swapper);

        StandardOrder memory order;
        {
            uint256[2][] memory inputs = new uint256[2][](1);
            inputs[0] = [tokenId, amount];
            MandateOutput[] memory outputs = new MandateOutput[](1);
            outputs[0] = MandateOutput({
                settler: address(outputSettlerCoin).toIdentifier(),
                oracle: address(alwaysYesOracle).toIdentifier(),
                chainId: block.chainid,
                token: address(anotherToken).toIdentifier(),
                amount: amount,
                recipient: swapper.toIdentifier(),
                callbackData: hex"",
                context: hex""
            });
            order = StandardOrder({
                user: address(swapper),
                nonce: 0,
                originChainId: block.chainid,
                fillDeadline: type(uint32).max,
                expires: type(uint32).max,
                inputOracle: alwaysYesOracle,
                inputs: inputs,
                outputs: outputs
            });
        }

        bytes memory signature;
        {
            // Make Compact
            uint256[2][] memory idsAndAmounts = new uint256[2][](1);
            idsAndAmounts[0] = [tokenId, amount];

            bytes memory sponsorSig = getCompactBatchWitnessSignature(
                swapperPrivateKey, inputSettlerCompact, swapper, 0, type(uint32).max, idsAndAmounts, witnessHash(order)
            );
            signature = abi.encode(sponsorSig, hex"");
        }
        // Other callers are disallowed:
        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);

        {
            vm.prank(non_solver);
            vm.expectRevert(abi.encodeWithSignature("InvalidSigner()"));
            solveParams[0] =
                InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: uint32(block.timestamp) });
            IInputSettlerCompact(inputSettlerCompact)
                .finaliseWithSignature(order, signature, solveParams, destination.toIdentifier(), hex"", hex"");
        }
        assertEq(token.balanceOf(destination), 0);

        bytes memory orderOwnerSignature = this.getOrderOpenSignature(
            solverPrivateKey,
            IInputSettlerCompact(inputSettlerCompact).orderIdentifier(order),
            destination.toIdentifier(),
            hex""
        );
        {
            bytes32[] memory solvers = new bytes32[](1);
            solvers[0] = solver.toIdentifier();
            vm.prank(non_solver);
            IInputSettlerCompact(inputSettlerCompact)
                .finaliseWithSignature(
                    order, signature, solveParams, destination.toIdentifier(), hex"", orderOwnerSignature
                );
        }

        vm.snapshotGasLastCall("inputSettler", "CompactFinaliseFor");

        assertEq(token.balanceOf(destination), amount);
    }
}
