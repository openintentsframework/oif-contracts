// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

import { InputSettlerPurchase } from "../../src/input/InputSettlerPurchase.sol";

import { InputSettlerBase } from "../../src/input/InputSettlerBase.sol";
import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { OrderPurchase, OrderPurchaseType } from "../../src/input/types/OrderPurchaseType.sol";
import { StandardOrder } from "../../src/input/types/StandardOrderType.sol";
import { LibAddress } from "../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../src/libs/MandateOutputEncodingLib.sol";
import { EIP712 } from "openzeppelin/utils/cryptography/EIP712.sol";

contract MockSettler is InputSettlerPurchase {
    constructor() EIP712("MockSettler", "-1") { }

    function purchaseGetOrderOwner(
        bytes32 orderId,
        InputSettlerBase.SolveParams[] calldata solveParams
    ) external returns (bytes32 orderOwner) {
        return _purchaseGetOrderOwner(orderId, solveParams);
    }

    function purchaseOrder(
        OrderPurchase calldata orderPurchase,
        uint256[2][] calldata inputs,
        bytes32 orderSolvedByIdentifier,
        bytes32 purchaser,
        uint256 expiryTimestamp,
        bytes calldata solverSignature
    ) external {
        _purchaseOrder(orderPurchase, inputs, orderSolvedByIdentifier, purchaser, expiryTimestamp, solverSignature);
    }

    function validateFills(
        uint32 fillDeadline,
        address inputOracle,
        MandateOutput[] calldata outputs,
        bytes32 orderId,
        InputSettlerBase.SolveParams[] calldata solveParams
    ) external view {
        _validateFills(fillDeadline, inputOracle, outputs, orderId, solveParams);
    }
}

contract BaseInputSettlerTest is Test {
    using LibAddress for address;
    using LibAddress for bytes32;

    MockSettler settler;
    bytes32 DOMAIN_SEPARATOR;

    MockERC20 token;
    MockERC20 anotherToken;

    uint256 purchaserPrivateKey;
    address purchaser;
    uint256 solverPrivateKey;
    address solver;

    function getOrderPurchaseSignature(
        uint256 privateKey,
        OrderPurchase calldata orderPurchase
    ) external view returns (bytes memory sig) {
        bytes32 msgHash = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, OrderPurchaseType.hashOrderPurchase(orderPurchase))
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function setUp() public virtual {
        settler = new MockSettler();
        DOMAIN_SEPARATOR = MockSettler(address(settler)).DOMAIN_SEPARATOR();

        token = new MockERC20("Mock ERC20", "MOCK", 18);
        anotherToken = new MockERC20("Mock2 ERC20", "MOCK2", 18);

        (purchaser, purchaserPrivateKey) = makeAddrAndKey("purchaser");
        (solver, solverPrivateKey) = makeAddrAndKey("swapper");
    }

    //--- Fill Validation ---//

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
                callbackData: hex"",
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
                callbackData: hex"",
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
        InputSettlerBase.SolveParams[] memory solveParams =
            new InputSettlerBase.SolveParams[](orderFulfillmentDescription.length);
        MandateOutput[] memory MandateOutputs = new MandateOutput[](orderFulfillmentDescription.length);
        for (uint256 i; i < orderFulfillmentDescription.length; ++i) {
            solveParams[i] = InputSettlerBase.SolveParams({
                solver: solverIdentifier, timestamp: orderFulfillmentDescription[i].timestamp
            });
            MandateOutputs[i] = orderFulfillmentDescription[i].MandateOutput;

            expectedProofPayload = abi.encodePacked(
                expectedProofPayload,
                MandateOutputs[i].chainId,
                MandateOutputs[i].oracle,
                MandateOutputs[i].settler,
                keccak256(
                    MandateOutputEncodingLib.encodeFillDescriptionMemory(
                        solverIdentifier, orderId, solveParams[i].timestamp, MandateOutputs[i]
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
            inputOracle: address(this),
            inputs: new uint256[2][](0), // not used
            outputs: MandateOutputs
        });

        settler.validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);
        vm.snapshotGasLastCall("inputSettler", "validate2Fills");
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
                callbackData: hex"",
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
                callbackData: hex"",
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
        InputSettlerBase.SolveParams[] memory solveParams =
            new InputSettlerBase.SolveParams[](orderFulfillmentDescriptionWithSolver.length);
        MandateOutput[] memory MandateOutputs = new MandateOutput[](orderFulfillmentDescriptionWithSolver.length);
        for (uint256 i; i < orderFulfillmentDescriptionWithSolver.length; ++i) {
            solveParams[i] = InputSettlerBase.SolveParams({
                solver: orderFulfillmentDescriptionWithSolver[i].solver,
                timestamp: orderFulfillmentDescriptionWithSolver[i].timestamp
            });
            MandateOutputs[i] = orderFulfillmentDescriptionWithSolver[i].MandateOutput;

            expectedProofPayload = abi.encodePacked(
                expectedProofPayload,
                MandateOutputs[i].chainId,
                MandateOutputs[i].oracle,
                MandateOutputs[i].settler,
                keccak256(
                    MandateOutputEncodingLib.encodeFillDescriptionMemory(
                        solveParams[i].solver, orderId, solveParams[i].timestamp, MandateOutputs[i]
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
            inputOracle: address(this),
            inputs: new uint256[2][](0), // not used
            outputs: MandateOutputs
        });

        settler.validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);
        vm.snapshotGasLastCall("inputSettler", "validate2FillsMultipleSolvers");
    }

    //--- Order Purchase ---//

    /// forge-config: default.isolate = true
    function test_purchase_order_gas() external {
        test_purchase_order(keccak256(bytes("orderId")));
    }

    function test_purchase_order(
        bytes32 orderId
    ) public {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);
        anotherToken.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](2);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;
        inputs[1][0] = uint256(uint160(address(anotherToken)));
        inputs[1][1] = amount;

        bytes32 orderSolvedByIdentifier = solver.toIdentifier();

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, callData: hex"", discount: 0, timeToBuy: 1000 });
        uint256 expiryTimestamp = type(uint256).max;
        bytes memory solverSignature = this.getOrderPurchaseSignature(solverPrivateKey, orderPurchase);

        uint32 currentTime = 10000;
        vm.warp(currentTime);

        vm.prank(purchaser);
        token.approve(address(settler), amount);
        vm.prank(purchaser);
        anotherToken.approve(address(settler), amount);

        // Check initial state:
        assertEq(token.balanceOf(solver), 0);
        assertEq(anotherToken.balanceOf(solver), 0);

        (uint32 storageLastOrderTimestamp, bytes32 storagePurchaser) =
            settler.purchasedOrders(orderSolvedByIdentifier, orderId);
        assertEq(storageLastOrderTimestamp, 0);
        assertEq(storagePurchaser, bytes32(0));

        vm.expectCall(
            address(token),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(purchaser), solver, amount)
        );
        vm.expectCall(
            address(anotherToken),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(purchaser), solver, amount)
        );

        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, purchaser.toIdentifier(), expiryTimestamp, solverSignature
        );
        vm.snapshotGasLastCall("inputSettler", "BasePurchaseOrder");

        // Check storage and balances.
        assertEq(token.balanceOf(solver), amount);
        assertEq(anotherToken.balanceOf(solver), amount);

        (storageLastOrderTimestamp, storagePurchaser) = settler.purchasedOrders(orderSolvedByIdentifier, orderId);
        assertEq(storageLastOrderTimestamp, currentTime - orderPurchase.timeToBuy);
        assertEq(storagePurchaser, purchaser.toIdentifier());

        // Try to purchase the same order again
        vm.expectRevert(abi.encodeWithSignature("AlreadyPurchased()"));
        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, purchaser.toIdentifier(), expiryTimestamp, solverSignature
        );
    }

    function test_error_purchase_order_validation(
        bytes32 orderId
    ) external {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);
        anotherToken.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](0);

        bytes32 orderSolvedByIdentifier = solver.toIdentifier();

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, callData: hex"", discount: 0, timeToBuy: 1000 });
        uint256 expiryTimestamp = type(uint256).max;
        bytes memory solverSignature = this.getOrderPurchaseSignature(solverPrivateKey, orderPurchase);

        uint32 currentTime = 10000;
        vm.warp(currentTime);

        vm.expectRevert(abi.encodeWithSignature("InvalidPurchaser()"));
        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, bytes32(0), expiryTimestamp, solverSignature
        );

        vm.expectRevert(abi.encodeWithSignature("Expired()"));
        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, purchaser.toIdentifier(), currentTime - 1, solverSignature
        );
    }

    function test_error_purchase_order_validation(
        bytes32 orderId,
        bytes calldata solverSignature
    ) external {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);
        anotherToken.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](0);

        bytes32 orderSolvedByIdentifier = solver.toIdentifier();

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, callData: hex"", discount: 0, timeToBuy: 1000 });
        uint256 expiryTimestamp = type(uint256).max;

        uint32 currentTime = 10000;
        vm.warp(currentTime);

        vm.expectRevert(abi.encodeWithSignature("InvalidSigner()"));
        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, purchaser.toIdentifier(), expiryTimestamp, solverSignature
        );
    }

    function test_purchase_order_call(
        bytes32 orderId,
        bytes calldata call
    ) external {
        vm.assume(call.length > 0);
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);
        anotherToken.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](2);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;
        inputs[1][0] = uint256(uint160(address(anotherToken)));
        inputs[1][1] = amount;

        bytes32 orderSolvedByIdentifier = solver.toIdentifier();

        OrderPurchase memory orderPurchase = OrderPurchase({
            orderId: orderId, destination: address(this), callData: call, discount: 0, timeToBuy: 1000
        });
        uint256 expiryTimestamp = type(uint256).max;
        bytes memory solverSignature = this.getOrderPurchaseSignature(solverPrivateKey, orderPurchase);

        uint32 currentTime = 10000;
        vm.warp(currentTime);

        vm.prank(purchaser);
        token.approve(address(settler), amount);
        vm.prank(purchaser);
        anotherToken.approve(address(settler), amount);

        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, purchaser.toIdentifier(), expiryTimestamp, solverSignature
        );

        assertEq(abi.encodePacked(_inputs), abi.encodePacked(inputs));
        assertEq(_executionData, call);
    }

    function test_error_dependent_on_purchase_order_call(
        bytes32 orderId,
        bytes calldata call
    ) external {
        vm.assume(call.length > 0);
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;

        bytes32 orderSolvedByIdentifier = solver.toIdentifier();

        OrderPurchase memory orderPurchase = OrderPurchase({
            orderId: orderId, destination: address(this), callData: call, discount: 0, timeToBuy: 1000
        });
        uint256 expiryTimestamp = type(uint256).max;
        bytes memory solverSignature = this.getOrderPurchaseSignature(solverPrivateKey, orderPurchase);

        uint32 currentTime = 10000;
        vm.warp(currentTime);

        vm.prank(purchaser);
        token.approve(address(settler), amount);

        failExternalCall = true;
        vm.expectRevert(abi.encodeWithSignature("ExternalFail()"));

        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, purchaser.toIdentifier(), expiryTimestamp, solverSignature
        );
    }

    error ExternalFail();

    bool failExternalCall;
    uint256[2][] _inputs;
    bytes _executionData;

    function orderFinalised(
        uint256[2][] calldata inputs,
        bytes calldata executionData
    ) external {
        if (failExternalCall) revert ExternalFail();

        _inputs = inputs;
        _executionData = executionData;
    }

    //--- Purchase Resolution ---//

    function test_purchase_order_then_resolve(
        bytes32 orderId
    ) external {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;

        bytes32 orderSolvedByIdentifier = solver.toIdentifier();

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, callData: hex"", discount: 0, timeToBuy: 1000 });
        uint256 expiryTimestamp = type(uint256).max;
        bytes memory solverSignature = this.getOrderPurchaseSignature(solverPrivateKey, orderPurchase);

        uint32 currentTime = 10000;
        vm.warp(currentTime);

        vm.prank(purchaser);
        token.approve(address(settler), amount);
        vm.prank(purchaser);
        anotherToken.approve(address(settler), amount);

        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, purchaser.toIdentifier(), expiryTimestamp, solverSignature
        );

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: currentTime });

        bytes32 collectedPurchaser = settler.purchaseGetOrderOwner(orderId, solveParams);
        assertEq(collectedPurchaser, purchaser.toIdentifier());
    }

    function test_purchase_order_then_resolve_early_first_fill_late_last(
        bytes32 orderId
    ) external {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;

        bytes32 orderSolvedByIdentifier = solver.toIdentifier();

        uint256 expiryTimestamp = type(uint256).max;
        address newDestination = solver;
        bytes memory call = hex"";
        uint48 discount = 0;
        uint32 timeToBuy = 1000;
        OrderPurchase memory orderPurchase = OrderPurchase({
            orderId: orderId, destination: newDestination, callData: call, discount: discount, timeToBuy: timeToBuy
        });
        bytes memory solverSignature = this.getOrderPurchaseSignature(solverPrivateKey, orderPurchase);

        uint32 currentTime = 10000;
        vm.warp(currentTime);

        vm.prank(purchaser);
        token.approve(address(settler), amount);
        vm.prank(purchaser);
        anotherToken.approve(address(settler), amount);

        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, purchaser.toIdentifier(), expiryTimestamp, solverSignature
        );

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](2);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: currentTime });
        solveParams[1] = InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: 0 });

        bytes32 collectedPurchaser = settler.purchaseGetOrderOwner(orderId, solveParams);
        assertEq(collectedPurchaser, purchaser.toIdentifier());
    }

    function test_purchase_order_then_resolve_too_late_purchase(
        bytes32 orderId
    ) external {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;

        bytes32 orderSolvedByIdentifier = solver.toIdentifier();

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, callData: hex"", discount: 0, timeToBuy: 1000 });
        uint256 expiryTimestamp = type(uint256).max;
        bytes memory solverSignature = this.getOrderPurchaseSignature(solverPrivateKey, orderPurchase);

        uint32 currentTime = 10000;
        vm.warp(currentTime);

        vm.prank(purchaser);
        token.approve(address(settler), amount);
        vm.prank(purchaser);
        anotherToken.approve(address(settler), amount);

        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase, inputs, orderSolvedByIdentifier, purchaser.toIdentifier(), expiryTimestamp, solverSignature
        );

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](2);
        solveParams[0] = InputSettlerBase.SolveParams({
            solver: solver.toIdentifier(), timestamp: currentTime - orderPurchase.timeToBuy - 1
        });
        solveParams[1] = InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: 0 });

        bytes32 collectedPurchaser = settler.purchaseGetOrderOwner(orderId, solveParams);
        assertEq(collectedPurchaser, orderSolvedByIdentifier);
    }

    function test_purchase_order_no_purchase(
        bytes32 orderId,
        bytes32 orderSolvedByIdentifier
    ) external {
        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](2);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: orderSolvedByIdentifier, timestamp: 0 });
        solveParams[1] = InputSettlerBase.SolveParams({ solver: orderSolvedByIdentifier, timestamp: 0 });

        bytes32 collectedPurchaser = settler.purchaseGetOrderOwner(orderId, solveParams);
        assertEq(collectedPurchaser, orderSolvedByIdentifier);
    }
}
