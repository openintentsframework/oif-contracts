// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// A contract that is able to interpret an order payload.
interface IOrderResolver {
    /// Function called by a filler with an order payload they received for this resolver.
    /// The returned resolved order contains fill instructions. The resolver must guarantee
    /// that following instructions results in proceeds being paid to the filler.
    function resolve(
        bytes calldata payload
    ) external returns (ResolvedOrder memory);
}

struct ResolvedOrder {
    /// The steps that must be performed by the filler, in the order given by
    /// dependencies between steps.
    Step[] steps;
    /// The variables that the filler must choose values for and inject into steps.
    /// Each element of the array is an ABI type. Variables will be referred to by their
    /// index in this array.
    string[] variableAbiTypes;
    /// The costs the filler will incur by following steps, not including gas costs.
    Leg[] costs;
    /// The proceeds the filler will earn by following steps.
    Leg[] proceeds;
    /// A list of addresses present in the order whose security the resolver cannot
    /// guarantee. The filler must validate each of them in their own whitelist.
    bytes[] untrusted;
}

struct Leg {
    /// An interoperable address for an ERC-20 token.
    bytes token;
    /// A formula given in ABI encoding for the Formula interface.
    bytes amountFormula;
}

struct Step {
    /// An action or pseudo-action given in ABI encoding for the Action interface.
    bytes action;
    /// A list of constraints given in ABI encoding for the Constraint interface.
    /// The action can only succeed if the constraints hold.
    bytes[] constraint;
    /// A list of other steps that this step depends on, given as indices into the
    /// ResolvedOrder steps array that contains this step.
    uint256[] dependencies;
}

// Use with abi.encodeCall
interface Action {
    /// The filler must send a transaction to target (interoperable address) with calldata
    /// abi.encodeWithSelector(selector, payload, v_0, ..., v_n)
    /// where v_0, ..., v_n are the values chosen for variables[0], ..., variables[n].
    function SendTx1(bytes memory target, bytes4 selector, bytes memory payload, uint256[] memory variables) external;

    /// The filler must perform an action with priorityFeePerGas given by a variable.
    function WithPriorityFee(uint256 priorityFeePerGasVariable, bytes memory action) external;

    /// The payload must be resolved on another resolver to get a list of steps to inject at this point.
    /// The resolved costs and proceeds are added to the order.
    function Yield(bytes memory resolver, bytes memory payload) external;

    // === Alternative to SendTx1 that doesn't require a bytes payload as first argument: ===

    /// The filler must send a transaction to target (interoperable address) with calldata
    /// abi.encodeWithSelector(selector, v_0, ..., v_n)
    /// where v_0, ..., v_n are the values chosen for variables[0], ..., variables[n]
    function SendTx2(bytes memory target, bytes4 selector, uint256[] memory variables) external;

    /// Pushes a new variable with a given value into the scope of `action`
    function WithVariable(string memory abiType, bytes memory abiEncodedValue, bytes memory action) external;
}

interface Constraint {
    /// The step can only be performed in a given time window.
    function TimeWindow(uint256 fromTimestampSec, uint256 untilTimestampSec) external;

    /// The step can only be performed if a call returns a specific result.
    function CallResult(
        address target,
        bytes4 selector,
        bytes memory payload,
        uint256[] memory variables,
        bytes memory result
    ) external;
}

interface Formula {
    function Const(
        uint256 value
    ) external;
    function Var(
        uint256 varIndex
    ) external;
    function Add(bytes memory lhs, bytes memory rhs) external;
    function Sub(bytes memory lhs, bytes memory rhs) external;
    function Mul(bytes memory lhs, bytes memory rhs) external;
    function Div(bytes memory lhs, bytes memory rhs) external;
    function Min(bytes memory a, bytes memory b) external;
    function Max(bytes memory a, bytes memory b) external;
}
