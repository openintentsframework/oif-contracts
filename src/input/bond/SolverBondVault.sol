// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin/utils/math/Math.sol";

import {
    ISignatureTransfer
} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {IERC3009} from "../../interfaces/IERC3009.sol";

import {BytesLib} from "../../libs/BytesLib.sol";
import {IsContractLib} from "../../libs/IsContractLib.sol";
import {LibAddress} from "../../libs/LibAddress.sol";

import {Permit2WitnessType} from "../escrow/Permit2WitnessType.sol";
import {StandardOrder} from "../types/StandardOrderType.sol";

/**
 * @title SolverBondVault
 * @notice Manages solver bond balances (deposit, withdraw, lock, unlock, penalize, slash) for ERC20 tokens.
 */

contract SolverBondVault {
    using SafeERC20 for IERC20;
    using LibAddress for uint256;

    // ------------------------- Errors -------------------------

    error ZeroAmount();
    error InvalidToken(address token);
    error AmountExceedsAvailableAmount(
        address solver,
        address token,
        uint256 amount
    );
    error AmountExceedsLockedAmount(
        address solver,
        address token,
        uint256 amount
    );
    error SlashBasisPointsTooHigh(uint256 slashBasisPoints);
    error SignatureAndInputsNotEqual();

    // ------------------------- Types -------------------------

    struct BondState {
        /// @dev Amount available for new orders
        uint256 availableAmount;
        /// @dev Amount currently locked in active orders
        uint256 lockedAmount;
    }

    // ------------------------- Events -------------------------

    /// @notice Emitted when a solver deposits bond tokens
    event BondDeposited(
        address indexed solver,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a solver withdraws available bond tokens
    event BondWithdrawn(
        address indexed solver,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a solver's bond is locked
    event BondLocked(
        address indexed solver,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a solver's bond is unlocked
    event BondUnlocked(
        address indexed solver,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a failed solver's locked bond is penalized and transferred to the recipient
    event BondPenalized(
        address indexed solver,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a failed solver's locked bond is slashed and transferred to the recipient
    event BondSlashed(
        address indexed solver,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );

    // ------------------------- Constants / Storage -------------------------

    /// @dev Signature type prefix used by settlers that accept multiple authorization mechanisms.
    bytes1 internal constant SIGNATURE_TYPE_PERMIT2 = 0x00;
    bytes1 internal constant SIGNATURE_TYPE_3009 = 0x01;
    bytes1 internal constant SIGNATURE_TYPE_SELF = 0xff;

    /// @dev Denominator for basis points calculations (100% = 10,000 BPS)
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 public immutable SLASH_BPS;

    mapping(address solver => mapping(address token => BondState))
        private _bondStates;

    // Address of the Permit2 contract.
    ISignatureTransfer constant PERMIT2 =
        ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // ------------------------- Constructor -------------------------

    /**
     * @notice Initialize SolverBondVault with slash basis points
     * @param slashBasisPoints The penalty percentage in basis points (0-10000)
     */
    constructor(uint256 slashBasisPoints) {
        if (slashBasisPoints > BPS_DENOMINATOR)
            revert SlashBasisPointsTooHigh(slashBasisPoints);
        SLASH_BPS = slashBasisPoints;
    }

    // ---------------------- External Functions ----------------------

    /**
     * @notice Deposit ERC20 tokens as bond for the caller.
     * @param token The ERC20 token address to deposit.
     * @param amount The amount of tokens to deposit
     */
    function depositBond(address token, uint256 amount) external {
        _validateZeroAmount(amount);
        _validateToken(token);

        IERC20 tokenContract = IERC20(token);

        uint256 balanceBefore = tokenContract.balanceOf(address(this));
        tokenContract.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = tokenContract.balanceOf(address(this));

        uint256 receivedAmount = balanceAfter - balanceBefore;
        _validateZeroAmount(receivedAmount);

        _bondStates[msg.sender][token].availableAmount += receivedAmount;
        emit BondDeposited(msg.sender, token, receivedAmount);
    }

    /**
     * @notice Withdraw available bond tokens to the caller.
     * @param token The ERC20 token address to withdraw from.
     * @param amount The amount of tokens to withdraw.
     */
    function withdrawBond(address token, uint256 amount) external {
        _validateZeroAmount(amount);
        _validateToken(token);

        BondState storage bondState = _bondStates[msg.sender][token];
        if (amount > bondState.availableAmount)
            revert AmountExceedsAvailableAmount(msg.sender, token, amount);

        bondState.availableAmount -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit BondWithdrawn(msg.sender, token, amount);
    }

    /**
     * @notice Get current bond state for a solver-token pair.
     * @param solver The solver address to query.
     * @param token The token address to query.
     * @return availableAmount Amount available for withdrawal or locking.
     * @return lockedAmount Amount currently locked.
     */
    function getBondState(
        address solver,
        address token
    ) external view returns (uint256 availableAmount, uint256 lockedAmount) {
        BondState memory bondState = _bondStates[solver][token];
        return (bondState.availableAmount, bondState.lockedAmount);
    }

    // ---------------------- Internal Functions ----------------------

    /**
     * @notice Lock bond balance for `solver`.
     * @dev This only updates accounting (available -> locked). It does not transfer any ERC20 tokens.
     * @param solver The solver address whose bonds will be locked.
     * @param token The token address to lock.
     * @param amount The amount of tokens to lock.
     */
    function _lockBond(address solver, address token, uint256 amount) internal {
        _validateZeroAmount(amount);
        _validateToken(token);

        BondState storage bondState = _bondStates[solver][token];

        if (amount > bondState.availableAmount)
            revert AmountExceedsAvailableAmount(solver, token, amount);

        bondState.availableAmount -= amount;
        bondState.lockedAmount += amount;

        emit BondLocked(solver, token, amount);
    }

    /**
     * @notice Lock solver bonds and transfer `inputs` from `sender` to `solver`.
     * @param sender The address to transfer tokens from.
     * @param solver The solver address whose bonds will be locked.
     * @param inputs The `[tokenId, amount]` inputs array.
     */
    function _lockBondsAndTransfer(
        address sender,
        address solver,
        uint256[2][] calldata inputs
    ) internal {
        uint256 inputsLength = inputs.length;

        for (uint256 i = 0; i < inputsLength; ++i) {
            uint256[2] calldata input = inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _lockBond(solver, token, amount);

            if (sender == address(this))
                IERC20(token).safeTransfer(solver, amount);
            else IERC20(token).safeTransferFrom(sender, solver, amount);
        }
    }

    /**
     * @notice Lock solver bonds and collect `order.inputs` from `signer` via Permit2, sending directly to `solver`.
     * @dev Reverts if Permit2 transfer fails or if any bond lock fails.
     * @param order StandardOrder representing the intent.
     * @param signer Provider of the Permit2 funds and signer of the intent.
     * @param signature Permit2 signature over the witness (see `Permit2WitnessType`).
     * @param solver The solver address whose bonds will be locked and who will receive the tokens.
     */
    function _lockBondsAndTransferWithPermit2(
        StandardOrder calldata order,
        address signer,
        bytes calldata signature,
        address solver
    ) internal {
        uint256 inputsLength = order.inputs.length;

        ISignatureTransfer.TokenPermissions[]
            memory permitted = new ISignatureTransfer.TokenPermissions[](
                inputsLength
            );
        ISignatureTransfer.SignatureTransferDetails[]
            memory transferDetails = new ISignatureTransfer.SignatureTransferDetails[](
                inputsLength
            );

        for (uint256 i; i < inputsLength; ++i) {
            uint256[2] calldata input = order.inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateZeroAmount(amount);
            _validateToken(token);

            // Set the allowance. This is the explicit max allowed amount approved by the user.
            permitted[i] = ISignatureTransfer.TokenPermissions({
                token: token,
                amount: amount
            });
            // Set our requested transfer. This has to be less than or equal to the allowance
            transferDetails[i] = ISignatureTransfer.SignatureTransferDetails({
                to: solver,
                requestedAmount: amount
            });

            _lockBond(solver, token, amount);
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
     * @notice Lock solver bonds and collect `inputs` from `signer` via ERC-3009, sending directly to `solver`.
     * @dev For the `receiveWithAuthorization` call, the nonce is set as the orderId to select the order associated with
     * the authorization.
     * @param orderId The order identifier used as nonce for authorization.
     * @param signer Provider of the ERC-3009 funds and signer of the authorization.
     * @param _signature_ Either a single ERC-3009 signature or abi.encoded bytes[] of signatures.
     * @param fillDeadline Deadline for calling the authorization.
     * @param solver The solver address whose bonds will be locked and who will receive the tokens.
     * @param inputs The inputs to be collected and locked.
     */
    function _lockBondsAndTransferWithAuthorization(
        bytes32 orderId,
        address signer,
        bytes calldata _signature_,
        uint32 fillDeadline,
        address solver,
        uint256[2][] calldata inputs
    ) internal {
        uint256 inputsLength = inputs.length;

        if (inputsLength == 1) {
            // If there is only 1 input, try using the provided signature as is.
            uint256[2] calldata input = inputs[0];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateZeroAmount(amount);
            _validateToken(token);

            bytes memory callData = abi.encodeCall(
                IERC3009.receiveWithAuthorization,
                (signer, solver, amount, 0, fillDeadline, orderId, _signature_)
            );
            (bool success, ) = token.call(callData);

            if (success) {
                _lockBond(solver, token, amount);
                return;
            }
            // Otherwise it could be because of a lot of reasons. One being the signature is abi.encoded as bytes[].
        }
        {
            uint256 signaturesLength = BytesLib.getLengthOfBytesArray(
                _signature_
            );
            if (inputsLength != signaturesLength)
                revert SignatureAndInputsNotEqual();
        }
        for (uint256 i; i < inputsLength; ++i) {
            uint256[2] calldata input = inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateZeroAmount(amount);
            _validateToken(token);

            _lockBond(solver, token, amount);

            bytes calldata signature = BytesLib.getBytesOfArray(_signature_, i);
            IERC3009(token).receiveWithAuthorization({
                from: signer,
                to: solver,
                value: amount,
                validAfter: 0,
                validBefore: fillDeadline,
                nonce: orderId,
                signature: signature
            });
        }
    }

    /**
     * @notice Unlock bonds of a solver
     * @param solver The solver address whose bonds will be unlocked
     * @param token The token address to unlock
     * @param amount The amount of tokens to unlock
     */
    function _unlockBond(
        address solver,
        address token,
        uint256 amount
    ) internal {
        _validateZeroAmount(amount);
        _validateToken(token);

        BondState storage bondState = _bondStates[solver][token];
        if (amount > bondState.lockedAmount)
            revert AmountExceedsLockedAmount(solver, token, amount);

        bondState.availableAmount += amount;
        bondState.lockedAmount -= amount;

        emit BondUnlocked(solver, token, amount);
    }

    /**
     * @notice Unlock bonds for a solver across multiple tokens
     * @param solver The solver address whose bonds will be unlocked
     * @param inputs The inputs of the order
     */
    function _unlockBonds(
        address solver,
        uint256[2][] calldata inputs
    ) internal {
        uint256 inputsLength = inputs.length;

        for (uint256 i = 0; i < inputsLength; ++i) {
            uint256[2] calldata input = inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _unlockBond(solver, token, amount);
        }
    }

    /**
     * @notice Unlock bonds for a solver and slash from their available balance
     * @param solver The solver address whose bonds will be unlocked
     * @param recipient The recipient address to receive the slashed tokens
     * @param inputs The inputs of the order
     */
    function _unlockAndSlashBonds(
        address solver,
        address recipient,
        uint256[2][] calldata inputs
    ) internal {
        uint256 inputsLength = inputs.length;

        for (uint256 i = 0; i < inputsLength; ++i) {
            uint256[2] calldata input = inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateZeroAmount(amount);
            _validateToken(token);

            BondState storage bondState = _bondStates[solver][token];
            if (amount > bondState.lockedAmount)
                revert AmountExceedsLockedAmount(solver, token, amount);

            bondState.availableAmount += amount;
            bondState.lockedAmount -= amount;

            emit BondUnlocked(solver, token, amount);

            uint256 slashAmount = _calculateSlashAmount(amount);
            uint256 actualSlashAmount = Math.min(
                slashAmount,
                bondState.availableAmount
            );

            if (actualSlashAmount > 0) {
                bondState.availableAmount -= actualSlashAmount;

                IERC20(token).safeTransfer(recipient, actualSlashAmount);

                emit BondSlashed(solver, recipient, token, actualSlashAmount);
            }
        }
    }

    /**
     * @notice Penalize locked bonds for a solver without slashing
     * @param solver The solver address whose bonds will be penalized
     * @param recipient The recipient address to receive the penalized tokens
     * @param inputs The inputs of the order
     */
    function _penalizeBonds(
        address solver,
        address recipient,
        uint256[2][] calldata inputs
    ) internal {
        uint256 inputsLength = inputs.length;

        for (uint256 i = 0; i < inputsLength; ++i) {
            uint256[2] calldata input = inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateZeroAmount(amount);
            _validateToken(token);

            BondState storage bondState = _bondStates[solver][token];

            if (amount > bondState.lockedAmount)
                revert AmountExceedsLockedAmount(solver, token, amount);

            bondState.lockedAmount -= amount;

            IERC20(token).safeTransfer(recipient, amount);

            emit BondPenalized(solver, recipient, token, amount);
        }
    }

    /**
     * @notice Penalize locked bonds and slash from available balance for a solver
     * @param solver The solver address whose bonds will be penalized
     * @param recipient The recipient address to receive the penalized and slashed tokens
     * @param inputs The inputs of the order
     */
    function _penalizeAndSlashBonds(
        address solver,
        address recipient,
        uint256[2][] calldata inputs
    ) internal {
        uint256 inputsLength = inputs.length;

        for (uint256 i = 0; i < inputsLength; ++i) {
            uint256[2] calldata input = inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateZeroAmount(amount);
            _validateToken(token);

            BondState storage bondState = _bondStates[solver][token];

            if (amount > bondState.lockedAmount)
                revert AmountExceedsLockedAmount(solver, token, amount);

            bondState.lockedAmount -= amount;

            uint256 slashAmount = _calculateSlashAmount(amount);
            uint256 actualSlashAmount = Math.min(
                slashAmount,
                bondState.availableAmount
            );

            if (actualSlashAmount > 0) {
                bondState.availableAmount -= actualSlashAmount;
                emit BondSlashed(solver, recipient, token, actualSlashAmount);
            }

            IERC20(token).safeTransfer(recipient, amount + actualSlashAmount);

            emit BondPenalized(solver, recipient, token, amount);
        }
    }

    function _transferInputs(
        address sender,
        address to,
        uint256[2][] calldata inputs
    ) internal {
        uint256 inputsLength = inputs.length;

        for (uint256 i = 0; i < inputsLength; ++i) {
            uint256[2] calldata input = inputs[i];

            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateZeroAmount(amount);
            _validateToken(token);

            IERC20(token).safeTransferFrom(sender, to, amount);
        }
    }

    /**
     * @notice Collect `order.inputs` from `signer` via Permit2 and send them to `to`.
     * @dev This helper does not lock/unlock any bonds; callers should update bond accounting separately if needed.
     * @param order StandardOrder containing inputs, nonce, and deadline used for Permit2.
     * @param signer Address providing funds and signing the Permit2 message.
     * @param signature Permit2 signature bytes (without the signature type prefix).
     * @param to Recipient of the transferred tokens.
     */
    function _transferInputsWithPermit2(
        StandardOrder calldata order,
        address signer,
        bytes calldata signature,
        address to
    ) internal {
        ISignatureTransfer.TokenPermissions[] memory permitted;
        ISignatureTransfer.SignatureTransferDetails[] memory transferDetails;

        {
            uint256 inputsLength = order.inputs.length;
            permitted = new ISignatureTransfer.TokenPermissions[](inputsLength);
            transferDetails = new ISignatureTransfer.SignatureTransferDetails[](
                inputsLength
            );

            for (uint256 i; i < inputsLength; ++i) {
                uint256[2] calldata input = order.inputs[i];
                address token = input[0].validatedCleanAddress();
                uint256 amount = input[1];

                _validateZeroAmount(amount);
                _validateToken(token);

                permitted[i] = ISignatureTransfer.TokenPermissions({
                    token: token,
                    amount: amount
                });

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

    function _transferInputsWithAuthorization(
        bytes32 orderId,
        address signer,
        bytes calldata _signature_,
        uint32 fillDeadline,
        address to,
        uint256[2][] calldata inputs
    ) internal {
        uint256 inputsLength = inputs.length;

        if (inputsLength == 1) {
            uint256[2] calldata input = inputs[0];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateZeroAmount(amount);
            _validateToken(token);

            bytes memory callData = abi.encodeCall(
                IERC3009.receiveWithAuthorization,
                (signer, to, amount, 0, fillDeadline, orderId, _signature_)
            );

            (bool success, ) = token.call(callData);
            if (success) return;
        }
        {
            uint256 signaturesLength = BytesLib.getLengthOfBytesArray(
                _signature_
            );
            if (inputsLength != signaturesLength)
                revert SignatureAndInputsNotEqual();
        }
        for (uint256 i; i < inputsLength; ++i) {
            uint256[2] calldata input = inputs[i];
            address token = input[0].validatedCleanAddress();
            uint256 amount = input[1];

            _validateZeroAmount(amount);
            _validateToken(token);

            bytes calldata signature = BytesLib.getBytesOfArray(_signature_, i);
            IERC3009(token).receiveWithAuthorization({
                from: signer,
                to: to,
                value: amount,
                validAfter: 0,
                validBefore: fillDeadline,
                nonce: orderId,
                signature: signature
            });
        }
    }

    // ---------------------- Helper Functions ----------------------

    /**
     * @dev Calculate slash amount using basis points with proper rounding
     * @param amount The amount to calculate slash penalty for
     * @return The calculated slash amount
     */
    function _calculateSlashAmount(
        uint256 amount
    ) private view returns (uint256) {
        if (amount == 0 || SLASH_BPS == 0) return 0;
        return Math.mulDiv(amount, SLASH_BPS, BPS_DENOMINATOR);
    }

    /**
     * @dev Validate that the token address is valid and contains code
     * @param token The token address to validate
     */
    function _validateToken(address token) internal view {
        if (token == address(0)) revert InvalidToken(token);
        IsContractLib.validateContainsCode(token);
    }

    /**
     * @dev Validate that the amount is not zero
     * @param amount The amount to validate
     */
    function _validateZeroAmount(uint256 amount) internal pure {
        if (amount == 0) revert ZeroAmount();
    }
}
