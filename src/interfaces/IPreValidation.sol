// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * @notice Validation logic that adds selective order validation logic.
 */
interface IPreValidation {
    /**
     * @notice Validate if the order shall progress.
     * @param validationKey Can contain various encoded logic for validation.
     * @param initiator Caller of initiate on the reactor. May or may not be the destination address (filler).
     */
    function validate(bytes32 validationKey, address initiator) external view returns (bool);
}
