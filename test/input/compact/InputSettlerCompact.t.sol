// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { TheCompact } from "the-compact/src/TheCompact.sol";

import { MandateOutput, MandateOutputType } from "../../../src/input/types/MandateOutputType.sol";
import { StandardOrder, StandardOrderType } from "../../../src/input/types/StandardOrderType.sol";
import { MandateOutputEncodingLib } from "../../../src/libs/MandateOutputEncodingLib.sol";
import { OutputSettlerCoin } from "../../../src/output/coin/OutputSettlerCoin.sol";

import { AlwaysYesOracle } from "../../mocks/AlwaysYesOracle.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { IInputSettlerCompactHarness, InputSettlerCompactTestBase } from "./InputSettlerCompact.base.t.sol";

contract InputSettlerCompactTest is InputSettlerCompactTestBase {
    event Transfer(address from, address to, uint256 amount);
    event Transfer(address by, address from, address to, uint256 id, uint256 amount);
    event CompactRegistered(address indexed sponsor, bytes32 claimHash, bytes32 typehash);
    event NextGovernanceFee(uint64 nextGovernanceFee, uint64 nextGovernanceFeeTime);
    event GovernanceFeeChanged(uint64 oldGovernanceFee, uint64 newGovernanceFee);

    uint64 constant GOVERNANCE_FEE_CHANGE_DELAY = 7 days;
    uint64 constant MAX_GOVERNANCE_FEE = 10 ** 18 * 0.05; // 10%

    address owner;

    function compactHash(
        address arbiter,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        StandardOrder calldata order
    ) external pure returns (bytes32) {
        return StandardOrderType.compactHash(arbiter, sponsor, nonce, expires, order);
    }

    // -- Units Tests -- //

    error InvalidProofSeries();

    mapping(bytes proofSeries => bool valid) _validProofSeries;

    function efficientRequireProven(
        bytes calldata proofSeries
    ) external view {
        if (!_validProofSeries[proofSeries]) revert InvalidProofSeries();
    }

    struct OrderFulfillmentDescription {
        uint32 timestamp;
        MandateOutput MandateOutput;
    }

    function test_validate_fills_one_solver(
        bytes32 solverIdentifier,
        bytes32 orderId,
        OrderFulfillmentDescription[] calldata orderFulfillmentDescription
    ) external {
        vm.assume(orderFulfillmentDescription.length > 0);

        address localOracle = address(this);

        bytes memory expectedProofPayload = hex"";
        uint32[] memory timestamps = new uint32[](orderFulfillmentDescription.length);
        MandateOutput[] memory MandateOutputs = new MandateOutput[](orderFulfillmentDescription.length);
        for (uint256 i; i < orderFulfillmentDescription.length; ++i) {
            timestamps[i] = orderFulfillmentDescription[i].timestamp;
            MandateOutputs[i] = orderFulfillmentDescription[i].MandateOutput;

            expectedProofPayload = abi.encodePacked(
                expectedProofPayload,
                MandateOutputs[i].chainId,
                MandateOutputs[i].oracle,
                MandateOutputs[i].settler,
                keccak256(
                    MandateOutputEncodingLib.encodeFillDescriptionM(
                        solverIdentifier, orderId, timestamps[i], MandateOutputs[i]
                    )
                )
            );
        }
        _validProofSeries[expectedProofPayload] = true;

        IInputSettlerCompactHarness(inputSettlerCompact).validateFills(
            StandardOrder({
                user: address(0),
                nonce: 0,
                originChainId: 0,
                expires: type(uint32).max,
                fillDeadline: type(uint32).max,
                localOracle: localOracle,
                inputs: new uint256[2][](0),
                outputs: MandateOutputs
            }),
            orderId,
            solverIdentifier,
            timestamps
        );
    }

    struct OrderFulfillmentDescriptionWithSolver {
        uint32 timestamp;
        bytes32 solver;
        MandateOutput MandateOutput;
    }

    function test_validate_fills_multiple_solvers(
        bytes32 orderId,
        OrderFulfillmentDescriptionWithSolver[] calldata orderFulfillmentDescriptionWithSolver
    ) external {
        vm.assume(orderFulfillmentDescriptionWithSolver.length > 0);
        address localOracle = address(this);

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
                    MandateOutputEncodingLib.encodeFillDescriptionM(
                        solvers[i], orderId, timestamps[i], MandateOutputs[i]
                    )
                )
            );
        }
        _validProofSeries[expectedProofPayload] = true;

        IInputSettlerCompactHarness(inputSettlerCompact).validateFills(
            StandardOrder({
                user: address(0),
                nonce: 0,
                originChainId: 0,
                expires: type(uint32).max,
                fillDeadline: type(uint32).max,
                localOracle: localOracle,
                inputs: new uint256[2][](0),
                outputs: MandateOutputs
            }),
            orderId,
            solvers,
            timestamps
        );
    }

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
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(address(alwaysYesOracle)))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            localOracle: alwaysYesOracle,
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

        bytes32 solverIdentifier = bytes32(uint256(uint160((solver))));

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        // Other callers are disallowed:
        vm.prank(non_solver);
        vm.expectRevert(abi.encodeWithSignature("NotOrderOwner()"));
        IInputSettlerCompactHarness(inputSettlerCompact).finaliseSelf(order, signature, timestamps, solverIdentifier);

        assertEq(token.balanceOf(solver), 0);

        {
            bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionM(
                solverIdentifier,
                IInputSettlerCompactHarness(inputSettlerCompact).orderIdentifier(order),
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
        }

        vm.prank(solver);
        IInputSettlerCompactHarness(inputSettlerCompact).finaliseSelf(order, signature, timestamps, solverIdentifier);
        vm.snapshotGasLastCall("inputSettler", "CompactFinaliseSelf");

        assertEq(token.balanceOf(solver), amount);
    }

    function test_revert_finalise_self_too_late(address non_solver, uint32 fillDeadline, uint32 filledAt) external {
        vm.assume(non_solver != solver);
        vm.assume(fillDeadline < filledAt);

        uint256 amount = 1e18 / 10;

        token.mint(swapper, amount);
        vm.prank(swapper);
        token.approve(address(theCompact), type(uint256).max);

        vm.prank(swapper);
        uint256 tokenId = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, amount, swapper);

        address localOracle = address(alwaysYesOracle);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [tokenId, amount];
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(localOracle))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: fillDeadline,
            expires: type(uint32).max,
            localOracle: alwaysYesOracle,
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

        bytes32 solverIdentifier = bytes32(uint256(uint160((solver))));

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = filledAt;

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("FilledTooLate(uint32,uint32)", fillDeadline, filledAt));
        IInputSettlerCompactHarness(inputSettlerCompact).finaliseSelf(order, signature, timestamps, solverIdentifier);
    }

    /// forge-config: default.isolate = true
    function test_finalise_to_gas() external {
        test_finalise_to(makeAddr("non_solver"), makeAddr("destination"));
    }

    function test_finalise_to(address non_solver, address destination) public {
        vm.assume(destination != inputSettlerCompact);
        vm.assume(destination != address(theCompact));
        vm.assume(destination != swapper);
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
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(address(alwaysYesOracle)))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            localOracle: alwaysYesOracle,
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

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        // Other callers are disallowed:

        vm.prank(non_solver);

        vm.expectRevert(abi.encodeWithSignature("NotOrderOwner()"));
        IInputSettlerCompactHarness(inputSettlerCompact).finaliseTo(
            order,
            signature,
            timestamps,
            bytes32(uint256(uint160((solver)))),
            bytes32(uint256(uint160(destination))),
            hex""
        );

        assertEq(token.balanceOf(destination), 0);

        vm.prank(solver);
        IInputSettlerCompactHarness(inputSettlerCompact).finaliseTo(
            order,
            signature,
            timestamps,
            bytes32(uint256(uint160((solver)))),
            bytes32(uint256(uint160(destination))),
            hex""
        );
        vm.snapshotGasLastCall("inputSettler", "CompactFinaliseTo");

        assertEq(token.balanceOf(destination), amount);
    }

    /// forge-config: default.isolate = true
    function test_finalise_for_gas() external {
        test_finalise_for(makeAddr("non_solver"), makeAddr("destination"));
    }

    function test_finalise_for(address non_solver, address destination) public {
        vm.assume(destination != inputSettlerCompact);
        vm.assume(destination != address(theCompact));
        vm.assume(destination != address(swapper));
        vm.assume(destination != address(solver));
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
            settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
            oracle: bytes32(uint256(uint160(address(alwaysYesOracle)))),
            chainId: block.chainid,
            token: bytes32(uint256(uint160(address(anotherToken)))),
            amount: amount,
            recipient: bytes32(uint256(uint160(swapper))),
            call: hex"",
            context: hex""
        });
        StandardOrder memory order = StandardOrder({
            user: address(swapper),
            nonce: 0,
            originChainId: block.chainid,
            fillDeadline: type(uint32).max,
            expires: type(uint32).max,
            localOracle: alwaysYesOracle,
            inputs: inputs,
            outputs: outputs
        });

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
        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(block.timestamp);

        // Other callers are disallowed:

        bytes memory orderOwnerSignature = hex"";

        vm.prank(non_solver);
        vm.expectRevert(abi.encodeWithSignature("InvalidSigner()"));
        IInputSettlerCompactHarness(inputSettlerCompact).finaliseFor(
            order,
            signature,
            timestamps,
            bytes32(uint256(uint160((solver)))),
            bytes32(uint256(uint160(destination))),
            hex"",
            orderOwnerSignature
        );

        assertEq(token.balanceOf(destination), 0);

        orderOwnerSignature = this.getOrderOpenSignature(
            solverPrivateKey,
            IInputSettlerCompactHarness(inputSettlerCompact).orderIdentifier(order),
            bytes32(uint256(uint160(destination))),
            hex""
        );

        vm.prank(non_solver);
        IInputSettlerCompactHarness(inputSettlerCompact).finaliseFor(
            order,
            signature,
            timestamps,
            bytes32(uint256(uint160((solver)))),
            bytes32(uint256(uint160(destination))),
            hex"",
            orderOwnerSignature
        );
        vm.snapshotGasLastCall("inputSettler", "CompactFinaliseFor");

        assertEq(token.balanceOf(destination), amount);
    }

    // --- Fee tests --- //

    // function test_invalid_governance_fee() public {
    //     vm.prank(owner);
    //     IInputSettlerCompactHarness(inputSettlerCompact).setGovernanceFee(MAX_GOVERNANCE_FEE);

    //     vm.prank(owner);
    //     vm.expectRevert(abi.encodeWithSignature("GovernanceFeeTooHigh()"));
    //     IInputSettlerCompactHarness(inputSettlerCompact).setGovernanceFee(MAX_GOVERNANCE_FEE + 1);

    //     vm.prank(owner);
    //     vm.expectRevert(abi.encodeWithSignature("GovernanceFeeTooHigh()"));
    //     IInputSettlerCompactHarness(inputSettlerCompact).setGovernanceFee(MAX_GOVERNANCE_FEE + 123123123);

    //     vm.prank(owner);
    //     vm.expectRevert(abi.encodeWithSignature("GovernanceFeeTooHigh()"));
    //     IInputSettlerCompactHarness(inputSettlerCompact).setGovernanceFee(type(uint64).max);
    // }

    // function test_governance_fee_change_not_ready(uint64 fee, uint256 timeDelay) public {
    //     vm.assume(fee <= MAX_GOVERNANCE_FEE);
    //     vm.assume(timeDelay < uint32(block.timestamp) + GOVERNANCE_FEE_CHANGE_DELAY);

    //     vm.prank(owner);
    //     vm.expectEmit();
    //     emit NextGovernanceFee(fee, uint32(block.timestamp) + GOVERNANCE_FEE_CHANGE_DELAY);
    //     IInputSettlerCompactHarness(inputSettlerCompact).setGovernanceFee(fee);

    //     vm.warp(timeDelay);
    //     vm.expectRevert(abi.encodeWithSignature("GovernanceFeeChangeNotReady()"));
    //     IInputSettlerCompactHarness(inputSettlerCompact).applyGovernanceFee();

    //     vm.warp(uint32(block.timestamp) + GOVERNANCE_FEE_CHANGE_DELAY + 1);

    //     assertEq(IInputSettlerCompactHarness(inputSettlerCompact).governanceFee(), 0);

    //     vm.expectEmit();
    //     emit GovernanceFeeChanged(0, fee);
    //     IInputSettlerCompactHarness(inputSettlerCompact).applyGovernanceFee();

    //     assertEq(IInputSettlerCompactHarness(inputSettlerCompact).governanceFee(), fee);
    // }

    // /// forge-config: default.isolate = true
    // function test_finalise_self_with_fee_gas() external {
    //     test_finalise_self_with_fee(MAX_GOVERNANCE_FEE / 3);
    // }

    // function test_finalise_self_with_fee(
    //     uint64 fee
    // ) public {
    //     vm.assume(fee <= MAX_GOVERNANCE_FEE);
    //     vm.prank(owner);
    //     IInputSettlerCompactHarness(inputSettlerCompact).setGovernanceFee(fee);
    //     vm.warp(uint32(block.timestamp) + GOVERNANCE_FEE_CHANGE_DELAY + 1);
    //     IInputSettlerCompactHarness(inputSettlerCompact).applyGovernanceFee();

    //     uint256 amount = 1e18 / 10;

    //     token.mint(swapper, amount);
    //     vm.prank(swapper);
    //     token.approve(address(theCompact), type(uint256).max);

    //     vm.prank(swapper);
    //     uint256 tokenId = theCompact.depositERC20(address(token), alwaysOkAllocatorLockTag, amount, swapper);

    //     uint256[2][] memory inputs = new uint256[2][](1);
    //     inputs[0] = [tokenId, amount];
    //     MandateOutput[] memory outputs = new MandateOutput[](1);
    //     outputs[0] = MandateOutput({
    //         settler: bytes32(uint256(uint160(address(outputSettlerCoin)))),
    //         oracle: bytes32(uint256(uint160(address(alwaysYesOracle)))),
    //         chainId: block.chainid,
    //         token: bytes32(uint256(uint160(address(anotherToken)))),
    //         amount: amount,
    //         recipient: bytes32(uint256(uint160(swapper))),
    //         call: hex"",
    //         context: hex""
    //     });
    //     StandardOrder memory order = StandardOrder({
    //         user: address(swapper),
    //         nonce: 0,
    //         originChainId: block.chainid,
    //         fillDeadline: type(uint32).max,
    //         expires: type(uint32).max,
    //         localOracle: alwaysYesOracle,
    //         inputs: inputs,
    //         outputs: outputs
    //     });

    //     // Make Compact
    //     uint256[2][] memory idsAndAmounts = new uint256[2][](1);
    //     idsAndAmounts[0] = [tokenId, amount];

    //     bytes memory sponsorSig = getCompactBatchWitnessSignature(
    //         swapperPrivateKey, address(inputSettlerCompact), swapper, 0, type(uint32).max, idsAndAmounts,
    // witnessHash(order)
    //     );

    //     bytes memory signature = abi.encode(sponsorSig, hex"");

    //     uint32[] memory timestamps = new uint32[](1);
    //     timestamps[0] = uint32(block.timestamp);

    //     uint256 govFeeAmount = (amount * fee) / 10 ** 18;
    //     uint256 amountPostFee = amount - govFeeAmount;

    //     vm.prank(solver);
    //     IInputSettlerCompactHarness(inputSettlerCompact).finaliseSelf(order, signature, timestamps,
    // bytes32(uint256(uint160((solver)))));
    //     vm.snapshotGasLastCall("inputSettler", "CompactFinaliseSelfWithFee");

    //     assertEq(token.balanceOf(solver), amountPostFee);
    //     assertEq(theCompact.balanceOf(owner, tokenId), govFeeAmount);
    // }
}
