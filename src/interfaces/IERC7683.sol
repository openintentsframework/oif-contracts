// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @title ResolvedCrossChainOrder type
/// @notice An implementation-generic representation of an order intended for filler consumption
/// @dev Defines all requirements for filling an order by unbundling the implementation-specific orderData.
/// @dev Intended to improve integration generalization by allowing fillers to compute the exact input and output
/// information of any order
struct ResolvedCrossChainOrder {
    /// @dev The address of the user account where funds are sourced from
    address user;
    /// @dev The chainId of the origin chain
    uint256 originChainId;
    /// @dev The timestamp by which the order must be opened. If zero, the open step is not necessary.
    uint32 openDeadline;
    /// @dev The timestamp by which the order must be filled on the destination chain(s)
    uint32 fillDeadline;
    /// @dev The timestamp by which the order must be settled on the origin chain
    uint32 settlementDeadline;
    /// @dev The unique identifier for this order within this settlement system
    bytes32 orderId;
    /// @dev The max outputs that the filler will send. It's possible the actual amount depends on the state of the
    /// destination
    ///      chain (destination dutch auction, for instance), so these outputs should be considered a cap on filler
    /// liabilities.
    Output[] maxSpent;
    /// @dev The minimum outputs that must be given to the filler as part of order settlement. Similar to maxSpent, it's
    /// possible
    ///      that special order types may not be able to guarantee the exact amount at open time, so this should be
    /// considered
    ///      a floor on filler receipts. Setting the `recipient` of an `Output` to address(0) indicates that the filler
    /// is not
    ///      known when creating this order.
    Output[] minReceived;
    /// @dev Each instruction in this array is parameterizes a single leg of the fill. This provides the filler with the
    /// information
    ///      necessary to perform the fill on the destination(s).
    FillInstruction[] fillInstructions;
    /// @dev Implementation-specific extensions with additional information or instructions about the order
    Extension[] extensions;
}

/// @notice Tokens that must be received for a valid order fulfillment
struct Output {
    /// @dev The address of the ERC20 token on the destination chain
    /// @dev address(0) used as a sentinel for the native token
    bytes32 token;
    /// @dev The amount of the token to be sent
    uint256 amount;
    /// @dev The address to receive the output tokens
    bytes32 recipient;
    /// @dev The destination chain for this output
    uint256 chainId;
}

/// @title FillInstruction type
/// @notice Instructions to parameterize each leg of the fill
/// @dev Provides all the origin-generated information required to produce a valid fill leg
struct FillInstruction {
    /// @dev The chain that this instruction is intended to be filled on
    uint256 destinationChainId;
    /// @dev The contract address that the instruction is intended to be filled on
    bytes32 destinationSettler;
    /// @dev The data generated on the origin chain needed by the destinationSettler to process the fill
    bytes originData;
    /// @dev The format in which the filler must encode `fillerData`
    ///      [TODO: elaborate specifics]
    string fillerDataFormat;
}

/// @notice Additional information or instructions about the order
struct Extension {
    /// @dev A human-readable ABI description of a function, without the `function` keyword.
    ///      E.g., "dutchAuction(uint256 startTime, uint256 endTime, uint256 startPrice, uint256 endPrice)"
    string abiDescription;
    /// @dev The extension parameters ABI-encoded according to `abiDescription`
    bytes data;
}

/// @notice Signals that an order has been opened
/// @param orderId a unique order identifier within this settlement system
/// @param order raw order in implementation-specific encoding
event Open(bytes32 indexed orderId, bytes order);

/// @title IOriginSettler
/// @notice Standard interface for settlement contracts on the origin chain
interface IOriginSettler {
    /// @notice Opens a gasless cross-chain order on behalf of a user.
    /// @dev This method must emit the Open event
    /// @param order The order in raw encoding
    /// @param user The user's address
    /// @param signature The user's signature over the order
    function openFor(bytes calldata order, address user, bytes calldata signature) external;

    /// @notice Opens a cross-chain order
    /// @dev To be called by the user
    /// @dev This method must emit the Open event
    /// @param order The order in raw encoding
    function open(
        bytes calldata order
    ) external;

    /// @notice Resolves a specific GaslessCrossChainOrder into a generic ResolvedCrossChainOrder
    /// @dev Intended to improve standardized integration of various order types and settlement contracts
    /// @param order The order in raw encoding
    /// @param user The user's address
    /// @param signature The user's signature over the order (optional)
    /// @return ResolvedCrossChainOrder hydrated order data including the inputs and outputs of the order
    function resolveFor(
        bytes calldata order,
        address user,
        bytes calldata signature
    ) external view returns (ResolvedCrossChainOrder memory);
}

/// @title IDestinationSettler
/// @notice Standard interface for settlement contracts on the destination chain
interface IDestinationSettler {
    /// @notice Fills a single leg of a particular order on the destination chain
    /// @param orderId Unique order identifier for this order
    /// @param originData Data emitted on the origin to parameterize the fill
    /// @param fillerData Data provided by the filler to inform the fill or express their preferences
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external;
}
