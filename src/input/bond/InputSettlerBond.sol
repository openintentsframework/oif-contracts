// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {EIP712} from "openzeppelin/utils/cryptography/EIP712.sol";
import {
    SignatureChecker
} from "openzeppelin/utils/cryptography/SignatureChecker.sol";

import {IInputOracle} from "../../interfaces/IInputOracle.sol";
import {IInputSettlerBond} from "../../interfaces/IInputSettlerBond.sol";

import {LibAddress} from "../../libs/LibAddress.sol";

import {InputSettlerBase} from "../InputSettlerBase.sol";
import {StandardOrder, StandardOrderType} from "../types/StandardOrderType.sol";

import {IERC3009} from "../../interfaces/IERC3009.sol";
import {BytesLib} from "../../libs/BytesLib.sol";
import {IsContractLib} from "../../libs/IsContractLib.sol";
import {Permit2WitnessType} from "../escrow/Permit2WitnessType.sol";
import {MandateOutput} from "../types/MandateOutputType.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ISignatureTransfer
} from "permit2/src/interfaces/ISignatureTransfer.sol";

/**
 * @title OIF Input Settler supporting a bond-based dispute mechanism.
 * @notice This implementation escrows input assets in the contract and introduces a bonding flow for solvers:
 * - A user (or sponsor) opens an order via `::open` or `::openFor`, depositing `order.inputs` into this contract.
 * - A solver claims the order via `::claim` by posting a bond (per-input) computed from `BOND_BPS`.
 * - During `DISPUTE_WINDOW`, anyone can dispute via `::dispute` by posting an equal bond.
 * - After `DISPUTE_WAITING_TIME`, the claim can be settled, distributing bonds depending on whether the claim is valid.
 *
 * Refunds are only allowed after `order.expires + DISPUTE_WINDOW + DISPUTE_WAITING_TIME` and only if the order was
 * never claimed/finalised.
 *
 * `::openFor` supports typed signatures:
 * - SIGNATURE_TYPE_PERMIT2:  b1:0x00 | bytes:signature
 * - SIGNATURE_TYPE_3009:     b1:0x01 | bytes:signature OR abi.encode(bytes[]:signatures)
 * - empty: self-funded open (requires msg.sender == sponsor)
 */
contract InputSettlerBond is InputSettlerBase, IInputSettlerBond {
    using SafeERC20 for IERC20;
    using StandardOrderType for StandardOrder;
    using LibAddress for uint256;
    using LibAddress for bytes32;
    using LibAddress for address;

    /**
     * @dev The order status is invalid.
     */
    error InvalidOrderStatus(OrderStatus);

    /**
     * @dev Reentrancy detected.
     */
    error ReentrancyDetected();

    /**
     * @dev The token amount is zero.
     */
    error ZeroTokenAmount();

    /**
     * @dev The token is invalid.
     */
    error InvalidToken(address token);

    /**
     * @dev The signature and inputs are not equal.
     */
    error SignatureAndInputsNotEqual();

    /**
     * Signature type not supported.
     */
    error SignatureNotSupported(bytes1);

    /**
     * @dev The bond basis points are too high.
     */
    error BondBpsTooHigh();

    /**
     * @dev The dispute window has expired.
     */
    error DisputeWindowExpired();

    /**
     * @dev The dispute window is not exceeded.
     */
    error DisputeWindowNotExceeded();

    /**
     * @dev The dispute waiting time is not exceeded.
     */
    error DisputeWaitingTimeNotExceeded();

    /**
     * @dev The caller is not authorised.
     */
    error NotAuthorised(address caller);

    /**
     * @dev The solve params hash is invalid.
     */
    error InvalidSolveParams(SolveParams[] solveParams);

    /**
     * @dev The claim already exists.
     */
    error ClaimAlreadyExists();

    /**
     * @dev The claim already disputed.
     */
    error ClaimDisputed();

    /**
     * @dev The claim is not disputed.
     */
    error ClaimNotDisputed();

    /**
     * @dev The claim is finalised.
     */
    error ClaimFinalised();

    /**
     * @notice Emitted when an order is opened.
     * @param orderId The order identifier.
     * @param order The order.
     */
    event Open(bytes32 indexed orderId, StandardOrder order);

    /**
     * @notice Emitted when an order is refunded.
     * @param orderId The order identifier.
     */
    event Refunded(bytes32 indexed orderId);

    /**
     * @notice Emitted when an order is claimed.
     * @param orderId The order identifier.
     * @param solver The solver.
     * @param order The order.
     * @param solveParams The solve parameters.
     */
    event Claimed(
        bytes32 indexed orderId,
        address indexed solver,
        StandardOrder order,
        SolveParams[] solveParams
    );

    /**
     * @notice Emitted when an order is disputed.
     * @param orderId The order identifier.
     * @param disputer The disputer.
     * @param order The order.
     * @param solveParams The solve parameters.
     */
    event Disputed(
        bytes32 indexed orderId,
        address indexed disputer,
        StandardOrder order,
        SolveParams[] solveParams
    );

    /**
     * @notice Emitted when an order is settled.
     * @param orderId The order identifier.
     * @param solveParamsHash The solve parameters hash.
     * @param isValidClaim Whether the claim is valid.
     */
    event Settled(
        bytes32 indexed orderId,
        bytes32 solveParamsHash,
        bool isValidClaim
    );

    /**
     * @notice High-level lifecycle status for an order.
     */
    enum OrderStatus {
        None,
        Deposited,
        Claimed,
        Refunded
    }

    /**
     * @notice Claim record keyed by (orderId, solveParamsHash).
     * @dev `claimTimestamp` and `disputeTimestamp` are used for time-window enforcement.
     */
    struct Claim {
        address solver;
        address disputer;
        uint32 claimTimestamp;
        uint32 disputeTimestamp;
        bool isFinalised;
    }

    /// Bond percentage (in basis points) charged on each input amount.
    uint32 public immutable BOND_BPS;
    /// Time window (in seconds) during which a claim can be disputed.
    uint32 public immutable DISPUTE_WINDOW;
    /// Additional time window (in seconds) after dispute for settlement/ slashing.
    uint32 public immutable DISPUTE_WAITING_TIME;

    /// Basis points denominator (100% = 10_000 bps).
    uint32 internal constant BPS_DENOMINATOR = 10_000;

    /// Signature types allowed.
    bytes1 internal constant SIGNATURE_TYPE_PERMIT2 = 0x00;
    bytes1 internal constant SIGNATURE_TYPE_3009 = 0x01;
    bytes1 internal constant SIGNATURE_TYPE_SELF = 0xff;

    /// Tracks order status by identifier.
    mapping(bytes32 orderId => OrderStatus) public orderStatus;
    /// Tracks claims by orderId and solveParams hash.
    mapping(bytes32 orderId => mapping(bytes32 solveParamsHash => Claim))
        public orderClaims;

    // Address of the Permit2 contract.
    ISignatureTransfer constant PERMIT2 =
        ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /**
     * @notice Constructs the InputSettlerBond contract.
     * @param disputeWindow The time window in seconds for the dispute window.
     * @param disputeWaitingTime The time window in seconds for the dispute waiting time.
     * @param bondBps The basis points to calculate the bond amount.
     */
    constructor(
        uint32 bondBps,
        uint32 disputeWindow,
        uint32 disputeWaitingTime
    ) EIP712(_domainName(), _domainVersion()) {
        if (bondBps > BPS_DENOMINATOR) revert BondBpsTooHigh();

        BOND_BPS = bondBps;
        DISPUTE_WINDOW = disputeWindow;
        DISPUTE_WAITING_TIME = disputeWaitingTime;
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

    // --- Open Orders --- //

    /**
     * @notice Collects input tokens directly from msg.sender.
     * @param order StandardOrder representing the intent.
     */
    function _open(StandardOrder calldata order) internal {
        uint256 numInputs = order.inputs.length;

        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = order.inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateToken(token);
            _validateTokenAmount(amount);

            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    /**
     * @notice Opens an intent for `order.user`. `order.inputs` tokens are collected from msg.sender.
     * @dev This function may make multiple sub-call calls either directly from this contract or from deeper inside the
     * call tree. To protect against reentry, the function uses the `orderStatus`.
     * @param order StandardOrder representing the intent.
     */
    function open(StandardOrder calldata order) external {
        _validateInputChain(order.originChainId);
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);
        _validateFillDeadlineBeforeExpiry(order.fillDeadline, order.expires);

        bytes32 orderId = order.orderIdentifier();
        _validateOrderStatus(orderId, OrderStatus.None);

        orderStatus[orderId] = OrderStatus.Deposited;

        _open(order);

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Deposited)
            revert ReentrancyDetected();

        emit Open(orderId, order);
    }

    /**
     * @notice Opens an intent for `order.user` sponsored by `sponsor`.
     * @dev Inputs are collected from `sponsor` and held by this contract until the order is refunded or claimed.
     * @param order StandardOrder representing the intent.
     * @param sponsor Address to collect tokens from.
     * @param signature Allowance signature from sponsor, optionally typed (Permit2 / ERC-3009), or empty for self.
     */
    function openFor(
        StandardOrder calldata order,
        address sponsor,
        bytes calldata signature
    ) external {
        _validateInputChain(order.originChainId);
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);
        _validateFillDeadlineBeforeExpiry(order.fillDeadline, order.expires);

        bytes32 orderId = order.orderIdentifier();
        _validateOrderStatus(orderId, OrderStatus.None);

        orderStatus[orderId] = OrderStatus.Deposited;

        if (signature.length == 0) {
            if (msg.sender != sponsor)
                revert SignatureNotSupported(SIGNATURE_TYPE_SELF);

            _open(order);
        } else {
            bytes1 signatureType = signature[0];

            if (signatureType == SIGNATURE_TYPE_PERMIT2) {
                _openForWithPermit2(
                    order,
                    sponsor,
                    signature[1:],
                    address(this)
                );
            } else if (signatureType == SIGNATURE_TYPE_3009) {
                _openForWithAuthorization(
                    order.inputs,
                    order.fillDeadline,
                    sponsor,
                    signature[1:],
                    orderId
                );
            } else {
                revert SignatureNotSupported(signatureType);
            }
        }

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Deposited)
            revert ReentrancyDetected();

        emit Open(orderId, order);
    }

    // --- Claim Orders --- //

    /**
     * @notice Creates a claim by collecting the solver bond and storing the claim record.
     * @dev The solver posts a bond proportional to each input amount.
     * @param orderId The order identifier.
     * @param order The order to claim.
     * @param solveParamsHash Hash of the solve parameters (used as claim key).
     */
    function _claim(
        bytes32 orderId,
        StandardOrder calldata order,
        bytes32 solveParamsHash
    ) internal {
        uint256 numInputs = order.inputs.length;

        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = order.inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            uint256 bondAmount = _calculateBondAmount(amount);

            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                bondAmount
            );
        }

        orderClaims[orderId][solveParamsHash] = Claim({
            solver: msg.sender,
            claimTimestamp: uint32(block.timestamp),
            disputer: address(0),
            disputeTimestamp: 0,
            isFinalised: false
        });
    }

    /**
     * @notice Claims an order by posting the bond. The claim can be disputed during `DISPUTE_WINDOW`.
     * @param order StandardOrder description of the intent.
     * @param solveParams Solve parameters for when the outputs were filled.
     */
    function claim(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams
    ) external {
        bytes32 orderId = order.orderIdentifier();
        _validateOrderStatus(orderId, OrderStatus.Deposited);

        if (solveParams.length != order.outputs.length)
            revert InvalidSolveParams(solveParams);
        if (msg.sender != solveParams[0].solver.fromIdentifier())
            revert NotAuthorised(msg.sender);

        bytes32 solveParamsHash = _getSolveParamsHash(solveParams);

        Claim memory orderClaim = orderClaims[orderId][solveParamsHash];

        if (orderClaim.claimTimestamp > 0) revert ClaimAlreadyExists();

        _claim(orderId, order, solveParamsHash);

        emit Claimed(orderId, msg.sender, order, solveParams);
    }

    // --- Dispute Claims --- //

    /**
     * @notice Disputes an existing claim by posting a matching bond and recording dispute metadata.
     * @param orderId The order identifier.
     * @param order StandardOrder description of the intent.
     * @param orderClaim Storage pointer to the claim being disputed.
     */
    function _dispute(
        bytes32 orderId,
        StandardOrder calldata order,
        Claim storage orderClaim
    ) internal {
        uint256 numInputs = order.inputs.length;

        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = order.inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            uint256 bondAmount = _calculateBondAmount(amount);

            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                bondAmount
            );
        }

        orderClaim.disputer = msg.sender;
        orderClaim.disputeTimestamp = uint32(block.timestamp);
    }

    /**
     * @notice Disputes a claim within `DISPUTE_WINDOW` by posting the bond.
     * @param order StandardOrder description of the intent.
     * @param solveParams Solve parameters for the claim being disputed.
     */
    function dispute(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams
    ) external {
        bytes32 orderId = order.orderIdentifier();

        bytes32 solveParamsHash = _getSolveParamsHash(solveParams);
        Claim storage orderClaim = orderClaims[orderId][solveParamsHash];

        // Avoid reentrancy / ensure the claim exists by checking an already-stored timestamp.
        if (orderClaim.claimTimestamp == 0)
            revert InvalidSolveParams(solveParams);

        if (orderClaim.disputeTimestamp > 0) revert ClaimDisputed();

        if (block.timestamp - orderClaim.claimTimestamp > DISPUTE_WINDOW)
            revert DisputeWindowExpired();

        _dispute(orderId, order, orderClaim);

        emit Disputed(orderId, msg.sender, order, solveParams);
    }

    // --- Finalise / Settle Claims --- //

    /**
     * @notice Finalises a claim by paying the solver the input amount plus the solver bond.
     * @dev This only transfers funds; status transitions are handled by the caller.
     * @param orderId The order identifier.
     * @param order StandardOrder description of the intent.
     * @param orderClaim Storage pointer to the claim being finalised.
     */
    function _finalise(
        bytes32 orderId,
        StandardOrder calldata order,
        Claim storage orderClaim
    ) internal {
        orderClaim.isFinalised = true;

        uint256 numInputs = order.inputs.length;

        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = order.inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            uint256 bondAmount = _calculateBondAmount(amount);

            IERC20(token).safeTransfer(orderClaim.solver, amount + bondAmount);
        }
    }

    /**
     * @notice Finalises an undisputed claim after `DISPUTE_WINDOW` has passed.
     * @param order StandardOrder description of the intent.
     * @param solveParams Solve parameters for the claim.
     */
    function finalise(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams
    ) external {
        bytes32 orderId = order.orderIdentifier();

        _validateOrderStatus(orderId, OrderStatus.Deposited);

        bytes32 solveParamsHash = _getSolveParamsHash(solveParams);

        Claim storage orderClaim = orderClaims[orderId][solveParamsHash];

        if (orderClaim.claimTimestamp == 0)
            revert InvalidSolveParams(solveParams);

        if (orderClaim.disputeTimestamp > 0) revert ClaimDisputed();

        if (orderClaim.isFinalised) revert ClaimFinalised();

        if (block.timestamp - orderClaim.claimTimestamp < DISPUTE_WINDOW)
            revert DisputeWindowNotExceeded();

        orderStatus[orderId] = OrderStatus.Claimed;

        _finalise(orderId, order, orderClaim);

        if (orderStatus[orderId] != OrderStatus.Claimed)
            revert ReentrancyDetected();

        emit Finalised(orderId, solveParams[0].solver, solveParams[0].solver);
    }

    /**
     * @notice Settles a disputed claim after `DISPUTE_WAITING_TIME` has passed.
     * @dev If the claim is valid, solver receives input + both bonds. Otherwise, disputer receives both bonds.
     * @param order StandardOrder description of the intent.
     * @param solveParams Solve parameters for the claim.
     */
    function settleDispute(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams
    ) external {
        bytes32 orderId = order.orderIdentifier();

        _validateOrderStatus(orderId, OrderStatus.Deposited);

        bytes32 solveParamsHash = _getSolveParamsHash(solveParams);

        Claim storage orderClaim = orderClaims[orderId][solveParamsHash];

        if (orderClaim.claimTimestamp == 0)
            revert InvalidSolveParams(solveParams);
        if (orderClaim.disputeTimestamp == 0) revert ClaimNotDisputed();
        if (orderClaim.isFinalised) revert ClaimFinalised();
        if (
            block.timestamp - orderClaim.disputeTimestamp < DISPUTE_WAITING_TIME
        ) {
            revert DisputeWaitingTimeNotExceeded();
        }

        orderClaim.isFinalised = true;

        bool isValidClaim = _validateClaim(
            order.fillDeadline,
            order.inputOracle,
            order.outputs,
            orderId,
            solveParams
        );

        if (isValidClaim) {
            orderStatus[orderId] = OrderStatus.Claimed;

            emit Finalised(
                orderId,
                solveParams[0].solver,
                solveParams[0].solver
            );
        }

        uint256 numInputs = order.inputs.length;

        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = order.inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            uint256 bondAmount = _calculateBondAmount(amount);

            if (isValidClaim) {
                IERC20(token).safeTransfer(
                    orderClaim.solver,
                    amount + (bondAmount * 2)
                );
            } else {
                IERC20(token).safeTransfer(
                    orderClaim.disputer,
                    (bondAmount * 2)
                );
            }
        }

        emit Settled(orderId, solveParamsHash, isValidClaim);
    }

    /**
     * @notice Slashes a disputed claim after the order has been resolved (Claimed or Refunded).
     * @dev This path distributes only the dispute bonds (2x bond) based on claim validity.
     * @param orderId The order identifier.
     * @param order StandardOrder description of the intent.
     * @param solveParams Solve parameters for the claim.
     * @param orderClaim Storage pointer to the claim.
     * @return isValidClaim Whether the claim is valid.
     */
    function _slashDispute(
        bytes32 orderId,
        StandardOrder calldata order,
        SolveParams[] calldata solveParams,
        Claim storage orderClaim
    ) internal returns (bool) {
        orderClaim.isFinalised = true;

        bool isValidClaim = _validateClaim(
            order.fillDeadline,
            order.inputOracle,
            order.outputs,
            orderId,
            solveParams
        );

        uint256 numInputs = order.inputs.length;

        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = order.inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            uint256 bondAmount = _calculateBondAmount(amount);
            uint256 disputeBondAmount = bondAmount * 2;

            if (isValidClaim) {
                IERC20(token).safeTransfer(
                    orderClaim.solver,
                    disputeBondAmount
                );
            } else {
                IERC20(token).safeTransfer(
                    orderClaim.disputer,
                    disputeBondAmount
                );
            }
        }

        return isValidClaim;
    }

    /**
     * @notice Slashes a disputed claim after the order has been resolved (Claimed or Refunded).
     * @param order StandardOrder description of the intent.
     * @param solveParams Solve parameters for the claim.
     */
    function slashDispute(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams
    ) external {
        bytes32 orderId = order.orderIdentifier();

        OrderStatus currentStatus = orderStatus[orderId];
        if (
            !(currentStatus == OrderStatus.Claimed ||
                currentStatus == OrderStatus.Refunded)
        ) {
            revert InvalidOrderStatus(currentStatus);
        }

        bytes32 solveParamsHash = _getSolveParamsHash(solveParams);

        Claim storage orderClaim = orderClaims[orderId][solveParamsHash];

        if (orderClaim.claimTimestamp == 0)
            revert InvalidSolveParams(solveParams);
        if (orderClaim.disputeTimestamp == 0) revert ClaimNotDisputed();
        if (orderClaim.isFinalised) revert ClaimFinalised();
        if (
            block.timestamp - orderClaim.disputeTimestamp < DISPUTE_WAITING_TIME
        ) {
            revert DisputeWaitingTimeNotExceeded();
        }

        bool isValidClaim = _slashDispute(
            orderId,
            order,
            solveParams,
            orderClaim
        );

        emit Settled(orderId, solveParamsHash, isValidClaim);
    }

    // --- Refund --- //

    /**
     * @notice Refunds the order inputs to `order.user`.
     * @param order StandardOrder description of the intent.
     */
    function _refund(StandardOrder calldata order) internal {
        uint256 numInputs = order.inputs.length;

        for (uint256 i; i < numInputs; ++i) {
            uint256[2] calldata input = order.inputs[i];

            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            IERC20(token).safeTransfer(order.user, amount);
        }
    }

    /**
     * @notice Refunds an order that was never claimed/finalised, once all dispute windows have passed.
     * @dev Refund is only allowed after `order.expires + DISPUTE_WINDOW + DISPUTE_WAITING_TIME`.
     * @param order StandardOrder description of the intent.
     */
    function refund(StandardOrder calldata order) external {
        _validateTimestampHasPassed(
            order.expires + DISPUTE_WINDOW + DISPUTE_WAITING_TIME
        );

        bytes32 orderId = order.orderIdentifier();
        _validateOrderStatus(orderId, OrderStatus.Deposited);

        orderStatus[orderId] = OrderStatus.Refunded;

        _refund(order);

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Refunded)
            revert ReentrancyDetected();

        emit Refunded(orderId);
    }

    // --- Permit2 / ERC-3009 helpers --- //

    /**
     * @notice Helper function for using Permit2 to collect assets represented by a StandardOrder.
     * @param order StandardOrder representing the intent.
     * @param signer Provider of the Permit2 funds and signer of the permit.
     * @param signature Permit2 signature with Permit2Witness representing `order`.
     * @param to Recipient of the input tokens. In most cases, should be address(this).
     */
    function _openForWithPermit2(
        StandardOrder calldata order,
        address signer,
        bytes calldata signature,
        address to
    ) internal {
        ISignatureTransfer.TokenPermissions[] memory permitted;
        ISignatureTransfer.SignatureTransferDetails[] memory transferDetails;

        {
            uint256 numInputs = order.inputs.length;
            permitted = new ISignatureTransfer.TokenPermissions[](numInputs);
            transferDetails = new ISignatureTransfer.SignatureTransferDetails[](
                numInputs
            );

            for (uint256 i; i < numInputs; ++i) {
                uint256[2] calldata input = order.inputs[i];
                address token = input[0].validatedCleanAddress();
                uint256 amount = input[1];

                _validateTokenAmount(amount);
                _validateToken(token);

                permitted[i] = ISignatureTransfer.TokenPermissions({
                    token: token,
                    amount: amount
                });
                // Set our requested transfer. This has to be less than or equal to the allowance
                transferDetails[i] = ISignatureTransfer
                    .SignatureTransferDetails({
                        to: to,
                        requestedAmount: amount
                    });
            }
        }
        ISignatureTransfer.PermitBatchTransferFrom
            memory permitBatch = ISignatureTransfer.PermitBatchTransferFrom({
                permitted: permitted,
                nonce: order.nonce,
                deadline: order.fillDeadline
            });
        PERMIT2.permitWitnessTransferFrom(
            permitBatch,
            transferDetails,
            signer,
            Permit2WitnessType.Permit2WitnessHash(order),
            Permit2WitnessType.PERMIT2_PERMIT2_TYPESTRING,
            signature
        );
    }

    /**
     * @notice Helper function for using ERC-3009 to collect assets represented by a StandardOrder.
     * @dev For `receiveWithAuthorization`, the nonce is set to `orderId` to bind authorizations to a specific order.
     * @param inputs Order inputs to be collected.
     * @param fillDeadline Deadline for calling the open function.
     * @param signer Provider of the ERC-3009 funds and signer of the authorization.
     * @param _signature_ Either a single ERC-3009 signature or abi.encoded bytes[] of signatures. A single signature is
     * only allowed if the order has exactly 1 input.
     * @param orderId The order identifier used as ERC-3009 nonce.
     */
    function _openForWithAuthorization(
        uint256[2][] calldata inputs,
        uint32 fillDeadline,
        address signer,
        bytes calldata _signature_,
        bytes32 orderId
    ) internal {
        uint256 numInputs = inputs.length;

        if (numInputs == 1) {
            // If there is only 1 input, try using the provided signature as is.
            uint256[2] calldata input = inputs[0];

            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateTokenAmount(amount);
            _validateToken(token);

            bytes memory callData = abi.encodeCall(
                IERC3009.receiveWithAuthorization,
                (
                    signer,
                    address(this),
                    amount,
                    0,
                    fillDeadline,
                    orderId,
                    _signature_
                )
            );

            (bool success, ) = token.call(callData);
            if (success) return;
            // Otherwise it could be because of a lot of reasons. One being the signature is abi.encoded as bytes[].
        }
        {
            uint256 numSignatures = BytesLib.getLengthOfBytesArray(_signature_);
            if (numInputs != numSignatures) revert SignatureAndInputsNotEqual();
        }
        for (uint256 i; i < numInputs; ++i) {
            bytes calldata signature = BytesLib.getBytesOfArray(_signature_, i);
            uint256[2] calldata input = inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateTokenAmount(amount);
            _validateToken(token);

            IERC3009(token).receiveWithAuthorization({
                from: signer,
                to: address(this),
                value: amount,
                validAfter: 0,
                validBefore: fillDeadline,
                nonce: orderId,
                signature: signature
            });
        }
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
     * @notice Validates that the token address is non-zero and contains contract code.
     * @param token ERC20 token address.
     */
    function _validateToken(address token) internal view {
        if (token == address(0)) revert InvalidToken(token);
        IsContractLib.validateContainsCode(token);
    }

    /**
     * @notice Validates that an amount is non-zero.
     * @param amount Token amount.
     */
    function _validateTokenAmount(uint256 amount) internal pure {
        if (amount == 0) revert ZeroTokenAmount();
    }

    /**
     * @notice Calculates the bond amount charged on a given input amount.
     * @dev Uses ceiling rounding to avoid under-collecting bond.
     * @param amount Input amount.
     * @return Bond amount.
     */
    function _calculateBondAmount(
        uint256 amount
    ) internal view returns (uint256) {
        return
            Math.mulDiv(amount, BOND_BPS, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }

    /**
     * @notice Validates a claim by requiring the oracle to prove all outputs for the provided `solveParams`.
     * @dev Returns false on any mismatch or missing proof; oracle is expected to revert when proofs are invalid.
     */
    function _validateClaim(
        uint32 fillDeadline,
        address inputOracle,
        MandateOutput[] calldata outputs,
        bytes32 orderId,
        SolveParams[] calldata solveParams
    ) internal view returns (bool) {
        uint256 numOutputs = outputs.length;
        if (solveParams.length != numOutputs) return false;

        bytes memory proofSeries = new bytes(32 * 4 * numOutputs);
        for (uint256 i; i < numOutputs; ++i) {
            uint32 outputFilledAt = solveParams[i].timestamp;
            if (fillDeadline < outputFilledAt) return false;

            MandateOutput calldata output = outputs[i];
            bytes32 payloadHash = _proofPayloadHash(
                orderId,
                solveParams[i].solver,
                outputFilledAt,
                output
            );

            uint256 chainId = output.chainId;
            bytes32 outputOracle = output.oracle;
            bytes32 outputSettler = output.settler;
            assembly ("memory-safe") {
                let offset := add(add(proofSeries, 0x20), mul(i, 0x80))
                mstore(offset, chainId)
                mstore(add(offset, 0x20), outputOracle)
                mstore(add(offset, 0x40), outputSettler)
                mstore(add(offset, 0x60), payloadHash)
            }
        }

        // Oracle is expected to revert if any proof is missing/invalid.
        try IInputOracle(inputOracle).efficientRequireProven(proofSeries) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Hashes solve params for use as a claim key.
     * @param solveParams Solve parameters.
     * @return Keccak256 hash of abi-encoded solve params.
     */
    function _getSolveParamsHash(
        SolveParams[] calldata solveParams
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(solveParams));
    }
}
