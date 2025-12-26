// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EIP712} from "openzeppelin/utils/cryptography/EIP712.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {
    SignatureChecker
} from "openzeppelin/utils/cryptography/SignatureChecker.sol";
import {InputSettlerBase} from "../InputSettlerBase.sol";
import {IInputSettlerBond} from "../../interfaces/IInputSettlerBond.sol";
import {BondManager} from "./BondManager.sol";
import {StandardOrder, StandardOrderType} from "../types/StandardOrderType.sol";
import {LibAddress} from "../../libs/LibAddress.sol";

/**
 * @title OIF Input Settler supporting using a bond.
 * @notice This implementation contains a bond system to manage input assets. Intents are initiated by
 * depositing assets through `::open`. Since tokens are collected on the `::open` call, it is important to wait for the
 * `::open` call to be final before filling the intent.
 *
 * If an order has not been finalised / claimed before `order.expires`, anyone may call `::refund` to send
 * `order.inputs` to `order.user`. Note that if this is not done, an order finalised after `order.expires` still claims
 * `order.inputs` for the solver.
 */
contract InputSettlerBond is BondManager, InputSettlerBase, IInputSettlerBond {
    using StandardOrderType for StandardOrder;
    using LibAddress for bytes32;
    using LibAddress for uint256;

    /**
     * @dev The solver signature is invalid.
     */
    error InvalidSolverSignature();

    /**
     * @dev The order status is invalid.
     */
    error InvalidOrderStatus(OrderStatus);

    /**
     * @dev Reentrancy detected.
     */
    error ReentrancyDetected();

    /**
     * @dev The order user is not the caller.
     */
    error NotOrderUser(address orderUser, address caller);

    /**
     * @notice Emitted when an order is opened.
     * @param orderId The order identifier.
     * @param order The order.
     */
    event Open(bytes32 indexed orderId, StandardOrder order);

    /**
     * @notice Emitted when an order is claimed.
     * @param orderId The order identifier.
     * @param order The order.
     */
    event Claimed(
        bytes32 indexed orderId,
        address indexed solver,
        StandardOrder order
    );

    /**
     * @notice Emitted when an order is refunded.
     * @param orderId The order identifier.
     */
    event Refunded(bytes32 indexed orderId);

    /**
     * Signature type not supported.
     */
    error SignatureNotSupported(bytes1);

    enum OrderStatus {
        None,
        Deposited,
        Claimed,
        Settled,
        Refunded
    }

    struct OrderSolver {
        address solver;
        uint256 timestamp;
    }
    bytes32 private constant ORDER_SOLVER_TYPEHASH =
        keccak256("Order(bytes32 orderId)");

    uint256 public immutable TIME_TO_FILL;

    mapping(bytes32 orderId => OrderStatus) public orderStatus;
    mapping(bytes32 orderId => OrderSolver) public orderSolver;

    /**
     * @notice Constructs the InputSettlerBond contract.
     * @param timeToFill The time window in seconds for the solver to fill the order.
     * @param slashBasisPoints The basis points to slash from bonds in case of penalties.
     */
    constructor(
        uint256 timeToFill,
        uint256 slashBasisPoints
    ) EIP712(_domainName(), _domainVersion()) BondManager(slashBasisPoints) {
        TIME_TO_FILL = timeToFill;
    }

    /**
     * @notice Returns the domain name of the EIP712 signature.
     * @dev This function is only called in the constructor and the returned value is cached
     * by the EIP712 base contract.
     * @return name The domain name.
     */
    function _domainName() internal view virtual returns (string memory) {
        return "OIFBond";
    }

    /**
     * @notice Returns the domain version of the EIP712 signature.
     * @dev This function is only called in the constructor and the returned value is cached
     * by the EIP712 base contract.
     * @return version The domain version.
     */
    function _domainVersion() internal view virtual returns (string memory) {
        return "1";
    }

    // --- Generic order identifier --- //

    /**
     * @notice Returns the unique identifier for a given order.
     * @param order StandardOrder representing the intent.
     * @return The unique order identifier.
     */
    function orderIdentifier(
        StandardOrder calldata order
    ) external view returns (bytes32) {
        return order.orderIdentifier();
    }

    /**
     * @notice Opens an intent for `order.user`. `order.inputs` tokens are collected from msg.sender.
     * @dev This function may make multiple sub-call calls either directly from this contract or from deeper inside the
     * call tree. To protect against reentry, the function uses the `orderStatus`.
     * @param order StandardOrder representing the intent.
     * @param solver The solver address.
     * @param solverSignature The solver signature.
     */
    function open(
        StandardOrder calldata order,
        address solver,
        bytes calldata solverSignature
    ) external {
        _validateInputChain(order.originChainId);
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);
        _validateFillDeadlineBeforeExpiry(order.fillDeadline, order.expires);

        bytes32 orderId = order.orderIdentifier();
        _validateOrderStatus(orderId, OrderStatus.None);

        _validateSolverSignature(solver, solverSignature, orderId);

        // Mark order as claimed. If we can't make the claim, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Claimed;

        _lockBondsAndTransfer(msg.sender, solver, order.inputs);

        // Store the solver for the order.
        orderSolver[orderId] = OrderSolver({
            solver: solver,
            timestamp: block.timestamp
        });

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Claimed)
            revert ReentrancyDetected();

        emit Open(orderId, order);
    }

    function open(StandardOrder calldata order) external {
        _validateInputChain(order.originChainId);
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);
        _validateFillDeadlineBeforeExpiry(order.fillDeadline, order.expires);

        bytes32 orderId = order.orderIdentifier();
        _validateOrderStatus(orderId, OrderStatus.None);

        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Deposited;

        uint256 inputsLength = order.inputs.length;

        for (uint256 i = 0; i < inputsLength; ++i) {
            uint256[2] calldata input = order.inputs[i];

            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            SafeERC20.safeTransferFrom(
                IERC20(token),
                msg.sender,
                address(this),
                amount
            );
        }

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Deposited)
            revert ReentrancyDetected();

        emit Open(orderId, order);
    }

    /**
     * @notice Opens an intent for `order.user`. `order.input` tokens are locked from solver's bonds and collected from `sponsor` through transferFrom, permit2 or ERC-3009.
     * @dev This function may make multiple sub-call calls either directly from this contract or from deeper inside the call tree.
     * To protect against reentry, the function uses the `orderStatus`. Local reentry (calling twice) is protected through a
     * checks-effect pattern while global reentry is enforced by not allowing existing the function with `orderStatus` not set to `Locked`.
     * @param order StandardOrder representing the intent.
     * @param sponsor Address to collect tokens from.
     * @param signature Allowance signature from sponsor with a signature type encoded as:
     * - SIGNATURE_TYPE_PERMIT2:  b1:0x00 | bytes:signature
     * - SIGNATURE_TYPE_3009:     b1:0x01 | bytes:signature OR abi.encode(bytes[]:signatures)
     * @param solver The solver whose bonds will be locked and who will receive the tokens.
     * @param solverSignature Signature from the solver authorizing their bond lock.
     */
    function openFor(
        StandardOrder calldata order,
        address sponsor,
        bytes calldata signature,
        address solver,
        bytes calldata solverSignature
    ) external {
        _validateInputChain(order.originChainId);
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);
        _validateFillDeadlineBeforeExpiry(order.fillDeadline, order.expires);

        bytes32 orderId = order.orderIdentifier();
        _validateOrderStatus(orderId, OrderStatus.None);

        _validateSolverSignature(solver, solverSignature, orderId);

        // Mark order as claimed. If we can't make the claim, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Claimed;

        if (signature.length == 0) {
            if (msg.sender != sponsor)
                revert SignatureNotSupported(SIGNATURE_TYPE_SELF);

            _lockBondsAndTransfer(sponsor, solver, order.inputs);
        } else {
            // Check the first byte of the signature for signature type then collect inputs.
            bytes1 signatureType = signature[0];

            if (signatureType == SIGNATURE_TYPE_PERMIT2) {
                _lockBondsAndTransferWithPermit2(
                    order,
                    sponsor,
                    signature[1:],
                    solver
                );
            } else if (signatureType == SIGNATURE_TYPE_3009) {
                _lockBondsAndTransferWithAuthorization(
                    orderId,
                    sponsor,
                    signature[1:],
                    order.fillDeadline,
                    solver,
                    order.inputs
                );
            } else {
                revert SignatureNotSupported(signatureType);
            }
        }

        // Store the solver for the order.
        orderSolver[orderId] = OrderSolver({
            solver: solver,
            timestamp: block.timestamp
        });

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Claimed)
            revert ReentrancyDetected();

        emit Open(orderId, order);
    }

    function claim(StandardOrder calldata order) external {
        bytes32 orderId = order.orderIdentifier();
        _validateOrderStatus(orderId, OrderStatus.Deposited);

        // Mark order as claimed. If we can't make the claim, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Claimed;

        _claim(orderId, order.inputs);

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Claimed)
            revert ReentrancyDetected();

        emit Claimed(orderId, msg.sender, order);
    }

    function _claim(bytes32 orderId, uint256[2][] calldata inputs) internal {
        _lockBondsAndTransfer(address(this), msg.sender, inputs);

        orderSolver[orderId] = OrderSolver({
            solver: msg.sender,
            timestamp: block.timestamp
        });
    }

    /**
     * @notice Finalises an order when called directly by the solver
     * @dev Finalise is not blocked after the expiry of orders.
     * The caller must be the address corresponding to the first solver in the solvers array.
     * @param order StandardOrder description of the intent.
     * @param solveParams List of solve parameters for when the outputs were filled.
     */
    function finalise(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams
    ) external {
        _validateInputChain(order.originChainId);

        bytes32 orderId = order.orderIdentifier();

        _validateOrderStatus(orderId, OrderStatus.Claimed);

        _validateFills(
            order.fillDeadline,
            order.inputOracle,
            order.outputs,
            orderId,
            solveParams
        );

        _finalise(order, orderId, solveParams);
    }

    /**
     * @notice Refunds an order that has not been finalised before it expired. This order may have been filled but
     * finalise has not been called yet.
     * @dev The bond system penalizes the solver when an order is refunded.
     * @param order StandardOrder description of the intent.
     */
    function refund(StandardOrder calldata order) external {
        _validateInputChain(order.originChainId);
        _validateTimestampHasPassed(order.expires);

        if (order.user != msg.sender)
            revert NotOrderUser(order.user, msg.sender);

        bytes32 orderId = order.orderIdentifier();

        // Mark order as refunded. If we can't make the refund, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Refunded;

        _refund(order, orderId);

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Refunded)
            revert ReentrancyDetected();

        emit Refunded(orderId);
    }

    function _refund(StandardOrder calldata order, bytes32 orderId) internal {
        OrderStatus status = orderStatus[orderId];

        if (status == OrderStatus.Claimed) {
            OrderSolver memory os = orderSolver[orderId];

            _penalizeBonds(os.solver, order.user, order.inputs);
        } else if (status == OrderStatus.Deposited) {
            uint256 inputsLength = order.inputs.length;

            for (uint256 i = 0; i < inputsLength; ++i) {
                uint256[2] calldata input = order.inputs[i];

                address token = input[0].validatedCleanAddress();
                uint256 amount = input[1];

                SafeERC20.safeTransfer(IERC20(token), order.user, amount);
            }
        } else {
            revert InvalidOrderStatus(status);
        }
    }

    /**
     * @notice Finalise an order, paying the inputs to the solver.
     * @dev This function handles bond management based on whether the fill was on time and who the solver is.
     * @param order The order that has been filled.
     * @param orderId A unique identifier for the order.
     * @param solveParams The solve parameters.
     */
    function _finalise(
        StandardOrder calldata order,
        bytes32 orderId,
        SolveParams[] calldata solveParams
    ) internal {
        // Mark order as settled. If we can't make the settle, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Settled;

        uint256 fillTimestamp = solveParams[0].timestamp;
        address solver = solveParams[0].solver.fromIdentifier();

        OrderSolver memory os = orderSolver[orderId];

        bool isOnTime = fillTimestamp <= os.timestamp + TIME_TO_FILL;

        if (isOnTime) {
            _unlockBonds(os.solver, order.inputs);
        } else if (os.solver == solver) {
            _unlockAndSlashBonds(os.solver, order.user, order.inputs);
        } else {
            _penalizeAndSlashBonds(os.solver, solver, order.inputs);
        }

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Settled)
            revert ReentrancyDetected();

        emit Finalised(orderId, solveParams[0].solver, solveParams[0].solver);
    }

    // --- Validation --- //

    /**
     * @notice Validates that an order has the expected status.
     * @param orderId The order identifier.
     * @param status The expected status.
     */
    function _validateOrderStatus(
        bytes32 orderId,
        OrderStatus status
    ) internal view {
        OrderStatus currentStatus = orderStatus[orderId];
        if (currentStatus != status) revert InvalidOrderStatus(currentStatus);
    }

    /**
     * @notice Validates the solver signature for an order.
     * @param solver The solver address.
     * @param solverSignature The signature to validate.
     * @param orderId The order identifier.
     */
    function _validateSolverSignature(
        address solver,
        bytes calldata solverSignature,
        bytes32 orderId
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(ORDER_SOLVER_TYPEHASH, orderId)
        );

        bytes32 digest = _hashTypedDataV4(structHash);

        if (
            !SignatureChecker.isValidSignatureNow(
                solver,
                digest,
                solverSignature
            )
        ) revert InvalidSolverSignature();
    }
}
