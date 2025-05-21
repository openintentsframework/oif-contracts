// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";

import { BaseSettler } from "src/settlers/BaseSettler.sol";
import { OrderPurchase, OrderPurchaseType } from "src/settlers/types/OrderPurchaseType.sol";

interface EIP712 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract MockSettler is BaseSettler {
    function _domainNameAndVersion()
        internal
        pure
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "MockSettler";
        version = "-1";
    }

    function purchaseGetOrderOwner(
        bytes32 orderId,
        bytes32 solver,
        uint32[] calldata timestamps
    ) external returns (bytes32 orderOwner) {
        return _purchaseGetOrderOwner(orderId, solver, timestamps);
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
}

contract BaseSettlerTest is Test {
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
        DOMAIN_SEPARATOR = EIP712(address(settler)).DOMAIN_SEPARATOR();

        token = new MockERC20("Mock ERC20", "MOCK", 18);
        anotherToken = new MockERC20("Mock2 ERC20", "MOCK2", 18);

        (purchaser, purchaserPrivateKey) = makeAddrAndKey("purchaser");
        (solver, solverPrivateKey) = makeAddrAndKey("swapper");
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

        bytes32 orderSolvedByIdentifier = bytes32(uint256(uint160(solver)));

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, call: hex"", discount: 0, timeToBuy: 1000 });
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
            orderPurchase,
            inputs,
            orderSolvedByIdentifier,
            bytes32(uint256(uint160(purchaser))),
            expiryTimestamp,
            solverSignature
        );
        vm.snapshotGasLastCall("settler", "BasePurchaseOrder");

        // Check storage and balances.
        assertEq(token.balanceOf(solver), amount);
        assertEq(anotherToken.balanceOf(solver), amount);

        (storageLastOrderTimestamp, storagePurchaser) = settler.purchasedOrders(orderSolvedByIdentifier, orderId);
        assertEq(storageLastOrderTimestamp, currentTime - orderPurchase.timeToBuy);
        assertEq(storagePurchaser, bytes32(uint256(uint160(purchaser))));

        // Try to purchase the same order again
        vm.expectRevert(abi.encodeWithSignature("AlreadyPurchased()"));
        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase,
            inputs,
            orderSolvedByIdentifier,
            bytes32(uint256(uint160(purchaser))),
            expiryTimestamp,
            solverSignature
        );
    }

    function test_error_purchase_order_validation(
        bytes32 orderId
    ) external {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);
        anotherToken.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](0);

        bytes32 orderSolvedByIdentifier = bytes32(uint256(uint160(solver)));

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, call: hex"", discount: 0, timeToBuy: 1000 });
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
            orderPurchase,
            inputs,
            orderSolvedByIdentifier,
            bytes32(uint256(uint160(purchaser))),
            currentTime - 1,
            solverSignature
        );
    }

    function test_error_purchase_order_validation(bytes32 orderId, bytes calldata solverSignature) external {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);
        anotherToken.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](0);

        bytes32 orderSolvedByIdentifier = bytes32(uint256(uint160(solver)));

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, call: hex"", discount: 0, timeToBuy: 1000 });
        uint256 expiryTimestamp = type(uint256).max;

        uint32 currentTime = 10000;
        vm.warp(currentTime);

        vm.expectRevert(abi.encodeWithSignature("InvalidSigner()"));
        vm.prank(purchaser);
        settler.purchaseOrder(
            orderPurchase,
            inputs,
            orderSolvedByIdentifier,
            bytes32(uint256(uint160(purchaser))),
            expiryTimestamp,
            solverSignature
        );
    }

    function test_purchase_order_call(bytes32 orderId, bytes calldata call) external {
        vm.assume(call.length > 0);
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);
        anotherToken.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](2);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;
        inputs[1][0] = uint256(uint160(address(anotherToken)));
        inputs[1][1] = amount;

        bytes32 orderSolvedByIdentifier = bytes32(uint256(uint160(solver)));

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: address(this), call: call, discount: 0, timeToBuy: 1000 });
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
            orderPurchase,
            inputs,
            orderSolvedByIdentifier,
            bytes32(uint256(uint160(purchaser))),
            expiryTimestamp,
            solverSignature
        );

        assertEq(abi.encodePacked(_inputs), abi.encodePacked(inputs));
        assertEq(_executionData, call);
    }

    function test_error_dependent_on_purchase_order_call(bytes32 orderId, bytes calldata call) external {
        vm.assume(call.length > 0);
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;

        bytes32 orderSolvedByIdentifier = bytes32(uint256(uint160(solver)));

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: address(this), call: call, discount: 0, timeToBuy: 1000 });
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
            orderPurchase,
            inputs,
            orderSolvedByIdentifier,
            bytes32(uint256(uint160(purchaser))),
            expiryTimestamp,
            solverSignature
        );
    }

    error ExternalFail();

    bool failExternalCall;
    uint256[2][] _inputs;
    bytes _executionData;

    function inputsFilled(uint256[2][] calldata inputs, bytes calldata executionData) external {
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

        bytes32 orderSolvedByIdentifier = bytes32(uint256(uint160(solver)));

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, call: hex"", discount: 0, timeToBuy: 1000 });
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
            orderPurchase,
            inputs,
            orderSolvedByIdentifier,
            bytes32(uint256(uint160(purchaser))),
            expiryTimestamp,
            solverSignature
        );

        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = currentTime;

        bytes32 collectedPurchaser = settler.purchaseGetOrderOwner(orderId, orderSolvedByIdentifier, timestamps);
        assertEq(collectedPurchaser, bytes32(uint256(uint160(purchaser))));
    }

    function test_purchase_order_then_resolve_early_first_fill_late_last(
        bytes32 orderId
    ) external {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;

        bytes32 orderSolvedByIdentifier = bytes32(uint256(uint160(solver)));

        uint256 expiryTimestamp = type(uint256).max;
        address newDestination = solver;
        bytes memory call = hex"";
        uint48 discount = 0;
        uint32 timeToBuy = 1000;
        OrderPurchase memory orderPurchase = OrderPurchase({
            orderId: orderId,
            destination: newDestination,
            call: call,
            discount: discount,
            timeToBuy: timeToBuy
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
            orderPurchase,
            inputs,
            orderSolvedByIdentifier,
            bytes32(uint256(uint160(purchaser))),
            expiryTimestamp,
            solverSignature
        );

        uint32[] memory timestamps = new uint32[](2);
        timestamps[0] = currentTime;
        timestamps[1] = 0;

        bytes32 collectedPurchaser = settler.purchaseGetOrderOwner(orderId, orderSolvedByIdentifier, timestamps);
        assertEq(collectedPurchaser, bytes32(uint256(uint160(purchaser))));
    }

    function test_purchase_order_then_resolve_too_late_purchase(
        bytes32 orderId
    ) external {
        uint256 amount = 10 ** 18;

        token.mint(purchaser, amount);

        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(address(token)));
        inputs[0][1] = amount;

        bytes32 orderSolvedByIdentifier = bytes32(uint256(uint160(solver)));

        OrderPurchase memory orderPurchase =
            OrderPurchase({ orderId: orderId, destination: solver, call: hex"", discount: 0, timeToBuy: 1000 });
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
            orderPurchase,
            inputs,
            orderSolvedByIdentifier,
            bytes32(uint256(uint160(purchaser))),
            expiryTimestamp,
            solverSignature
        );

        uint32[] memory timestamps = new uint32[](2);
        timestamps[0] = currentTime - orderPurchase.timeToBuy - 1;
        timestamps[1] = 0;

        bytes32 collectedPurchaser = settler.purchaseGetOrderOwner(orderId, orderSolvedByIdentifier, timestamps);
        assertEq(collectedPurchaser, orderSolvedByIdentifier);
    }

    function test_purchase_order_no_purchase(bytes32 orderId, bytes32 orderSolvedByIdentifier) external {
        uint32[] memory timestamps = new uint32[](2);

        bytes32 collectedPurchaser = settler.purchaseGetOrderOwner(orderId, orderSolvedByIdentifier, timestamps);
        assertEq(collectedPurchaser, orderSolvedByIdentifier);
    }
}
