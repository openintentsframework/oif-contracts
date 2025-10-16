// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// End consumer library.
// / @notice
// /
// https://github.com/smartcontractkit/chainlink-ccip/blob/632b2acd4f2b203fe4cdd3e93ac0e1303a10ff56/chains/evm/contracts/libraries/Client.sol
library Client {
    /// @dev RMN depends on this struct, if changing, please notify the RMN maintainers.
    struct EVMTokenAmount {
        address token; // token address on the local chain.
        uint256 amount; // Amount of tokens.
    }

    struct Any2EVMMessage {
        bytes32 messageId; // MessageId corresponding to ccipSend on source.
        uint64 sourceChainSelector; // Source chain selector.
        bytes sender; // abi.decode(sender) if coming from an EVM chain.
        bytes data; // payload sent in original message.
        EVMTokenAmount[] destTokenAmounts; // Tokens and their amounts in their destination chain representation.
    }

    // If extraArgs is empty bytes, the default is 200k gas limit.
    struct EVM2AnyMessage {
        bytes receiver; // abi.encode(receiver address) for dest EVM chains.
        bytes data; // Data payload.
        EVMTokenAmount[] tokenAmounts; // Token transfers.
        address feeToken; // Address of feeToken. address(0) means you will send msg.value.
        bytes extraArgs; // Populate this with _argsToBytes(EVMExtraArgsV2).
    }

    // Tag to indicate only a gas limit. Only usable for EVM as destination chain.
    bytes4 public constant EVM_EXTRA_ARGS_V1_TAG = 0x97a657c9;

    struct EVMExtraArgsV1 {
        uint256 gasLimit;
    }

    function _argsToBytes(
        EVMExtraArgsV1 memory extraArgs
    ) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(EVM_EXTRA_ARGS_V1_TAG, extraArgs);
    }

    // Tag to indicate a gas limit (or dest chain equivalent processing units) and Out Of Order Execution. This tag is
    // available for multiple chain families. If there is no chain family specific tag, this is the default available
    // for a chain.
    // Note: not available for Solana VM based chains.
    bytes4 public constant GENERIC_EXTRA_ARGS_V2_TAG = 0x181dcf10;

    /// @param gasLimit: gas limit for the callback on the destination chain.
    /// @param allowOutOfOrderExecution: if true, it indicates that the message can be executed in any order relative to
    /// other messages from the same sender. This value's default varies by chain. On some chains, a particular value is
    /// enforced, meaning if the expected value is not set, the message request will revert.
    /// @dev Fully compatible with the previously existing EVMExtraArgsV2.
    struct GenericExtraArgsV2 {
        uint256 gasLimit;
        bool allowOutOfOrderExecution;
    }

    // Extra args tag for chains that use the Sui VM.
    bytes4 public constant SUI_EXTRA_ARGS_V1_TAG = 0x21ea4ca9;

    // Extra args tag for chains that use the Solana VM.
    bytes4 public constant SVM_EXTRA_ARGS_V1_TAG = 0x1f3b3aba;

    struct SVMExtraArgsV1 {
        uint32 computeUnits;
        uint64 accountIsWritableBitmap;
        bool allowOutOfOrderExecution;
        bytes32 tokenReceiver;
        // Additional accounts needed for execution of CCIP receiver. Must be empty if message.receiver is zero.
        // Token transfer related accounts are specified in the token pool lookup table on SVM.
        bytes32[] accounts;
    }

    /// @dev The maximum number of accounts that can be passed in SVMExtraArgs.
    uint256 public constant SVM_EXTRA_ARGS_MAX_ACCOUNTS = 64;

    /// @dev The expected static payload size of a token transfer when Borsh encoded and submitted to SVM.
    /// TokenPool extra data and offchain data sizes are dynamic, and should be accounted for separately.
    uint256 public constant SVM_TOKEN_TRANSFER_DATA_OVERHEAD =
        (4 + 32) // source_pool
        + 32 // token_address
        + 4 // gas_amount
        + 4 // extra_data overhead
        + 32 // amount
        + 32 // size of the token lookup table account
        + 32 // token-related accounts in the lookup table, over-estimated to 32, typically between 11 - 13
        + 32 // token account belonging to the token receiver, e.g ATA, not included in the token lookup table
        + 32 // per-chain token pool config, not included in the token lookup table
        + 32 // per-chain token billing config, not always included in the token lookup table
        + 32; // OffRamp pool signer PDA, not included in the token lookup table

    /// @dev Number of overhead accounts needed for message execution on SVM.
    /// @dev These are message.receiver, and the OffRamp Signer PDA specific to the receiver.
    uint256 public constant SVM_MESSAGING_ACCOUNTS_OVERHEAD = 2;

    /// @dev The size of each SVM account address in bytes.
    uint256 public constant SVM_ACCOUNT_BYTE_SIZE = 32;

    struct SuiExtraArgsV1 {
        uint256 gasLimit;
        bool allowOutOfOrderExecution;
        bytes32 tokenReceiver;
        bytes32[] receiverObjectIds;
    }

    /// @dev The expected static payload size of a token transfer when Borsh encoded and submitted to SUI.
    /// TokenPool extra data and offchain data sizes are dynamic, and should be accounted for separately.
    uint256 public constant SUI_TOKEN_TRANSFER_DATA_OVERHEAD =
        (4 + 32) // source_pool
        + 32 // token_address
        + 4 // gas_amount
        + 4 // extra_data overhead
        + 32 // amount
        + 32 // size of the token lookup table account
        + 32 // token-related accounts in the lookup table, over-estimated to 32, typically between 11 - 13
        + 32 // token account belonging to the token receiver, e.g ATA, not included in the token lookup table
        + 32 // per-chain token pool config, not included in the token lookup table
        + 32; // per-chain token billing config, not always included in the token lookup table

    /// @dev Number of overhead accounts needed for message execution on SUI.
    /// @dev This is the message.receiver.
    uint256 public constant SUI_MESSAGING_ACCOUNTS_OVERHEAD = 1;

    /// @dev The maximum number of receiver object ids that can be passed in SuiExtraArgs.
    uint256 public constant SUI_EXTRA_ARGS_MAX_RECEIVER_OBJECT_IDS = 64;

    /// @dev The size of each SUI account address in bytes.
    uint256 public constant SUI_ACCOUNT_BYTE_SIZE = 32;

    function _argsToBytes(
        GenericExtraArgsV2 memory extraArgs
    ) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V2_TAG, extraArgs);
    }

    function _svmArgsToBytes(
        SVMExtraArgsV1 memory extraArgs
    ) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(SVM_EXTRA_ARGS_V1_TAG, extraArgs);
    }

    function _suiArgsToBytes(
        SuiExtraArgsV1 memory extraArgs
    ) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(SUI_EXTRA_ARGS_V1_TAG, extraArgs);
    }

    /// @notice The CCV struct is used to represent a cross-chain verifier.
    struct CCV {
        /// @param The ccvAddress is the address of the verifier contract on the source chain
        address ccvAddress;
        /// @param args The args are the arguments that the verifier contract expects. They are opaque to CCIP and are
        /// only
        /// used in the CCV.
        bytes args;
    }

    bytes4 public constant GENERIC_EXTRA_ARGS_V3_TAG = 0x302326cb;

    struct EVMExtraArgsV3 {
        CCV[] requiredCCV;
        CCV[] optionalCCV;
        uint8 optionalThreshold;
        /// @notice The finality config, 0 means the default finality that the CCV considers final. Any non-zero value
        /// means
        /// a block depth.
        uint16 finalityConfig;
        address executor;
        bytes executorArgs;
        bytes tokenArgs;
    }

    function _argsToBytes(
        EVMExtraArgsV3 memory extraArgs
    ) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V3_TAG, extraArgs);
    }
}
