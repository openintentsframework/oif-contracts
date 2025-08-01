import { console } from "forge-std/console.sol";

library OutputFillLib {
    bytes1 constant LIMIT_ORDER = 0x00;
    bytes1 constant DUTCH_AUCTION = 0x01;
    bytes1 constant EXCLUSIVE_LIMIT_ORDER = 0xe0;
    bytes1 constant EXCLUSIVE_DUTCH_AUCTION = 0xe1;

    error InvalidContextDataLength();

    function fillDeadline(
        bytes calldata output
    ) internal pure returns (uint48 fillDeadline) {
        assembly ("memory-safe") {
            fillDeadline := shr(208, calldataload(add(output.offset, 0x00)))
        }
    }

    function oracle(
        bytes calldata output
    ) internal pure returns (bytes32 oracle) {
        assembly ("memory-safe") {
            oracle := calldataload(add(output.offset, 0x06))
        }
    }

    function settler(
        bytes calldata output
    ) internal pure returns (bytes32 settler) {
        assembly ("memory-safe") {
            settler := calldataload(add(output.offset, 0x26))
        }
    }

    function chainId(
        bytes calldata output
    ) internal pure returns (uint256 chainId) {
        assembly ("memory-safe") {
            chainId := calldataload(add(output.offset, 0x46))
        }
    }

    function token(
        bytes calldata output
    ) internal pure returns (bytes32 token) {
        assembly ("memory-safe") {
            token := calldataload(add(output.offset, 0x66))
        }
    }

    function amount(
        bytes calldata output
    ) internal pure returns (uint256 amount) {
        assembly ("memory-safe") {
            amount := calldataload(add(output.offset, 0x86))
        }
    }

    function recipient(
        bytes calldata output
    ) internal pure returns (bytes32 recipient) {
        assembly ("memory-safe") {
            recipient := calldataload(add(output.offset, 0xa6))
        }
    }

    function callbackData(
        bytes calldata output
    ) internal pure returns (bytes calldata _callbackData) {
        assembly ("memory-safe") {
            let length := shr(240, calldataload(add(output.offset, 0xc6)))

            _callbackData.offset := add(output.offset, 0xc8)
            _callbackData.length := length
        }
    }

    function contextData(
        bytes calldata output
    ) internal pure returns (bytes calldata _contextData) {
        assembly ("memory-safe") {
            let callbackDataLength := shr(240, calldataload(add(output.offset, 0xc6)))
            let contextLengthOffset := add(add(output.offset, 0xc8), callbackDataLength)
            let contextLength := shr(240, calldataload(contextLengthOffset))

            _contextData.offset := add(contextLengthOffset, 0x02)
            _contextData.length := contextLength
        }
    }

    // --- Context Data --- //
    function orderType(
        bytes calldata contextData
    ) internal pure returns (bytes1 orderType) {
        assembly ("memory-safe") {
            orderType := calldataload(contextData.offset)
        }
    }

    function getDutchAuctionData(
        bytes calldata contextData
    ) internal pure returns (uint32 startTime, uint32 stopTime, uint256 slope) {
        if (contextData.length != 41) revert InvalidContextDataLength();
        assembly ("memory-safe") {
            startTime := shr(224, calldataload(add(contextData.offset, 0x01))) // bytes[1:5]
            stopTime := shr(224, calldataload(add(contextData.offset, 0x05))) // bytes[5:9]
            slope := calldataload(add(contextData.offset, 0x09)) // bytes[9:41]
        }
    }

    function getExclusiveLimitOrderData(
        bytes calldata contextData
    ) internal pure returns (bytes32 exclusiveFor, uint32 startTime) {
        if (contextData.length != 37) revert InvalidContextDataLength();
        assembly ("memory-safe") {
            exclusiveFor := calldataload(add(contextData.offset, 0x01)) // bytes[1:33]
            startTime := shr(224, calldataload(add(contextData.offset, 0x21))) // bytes[33:37]
        }
    }

    function getExclusiveDutchAuctionData(
        bytes calldata contextData
    ) internal pure returns (bytes32 exclusiveFor, uint32 startTime, uint32 stopTime, uint256 slope) {
        if (contextData.length != 73) revert InvalidContextDataLength();
        assembly ("memory-safe") {
            exclusiveFor := calldataload(add(contextData.offset, 0x01)) // bytes[1:33]
            startTime := shr(224, calldataload(add(contextData.offset, 0x21))) // bytes[33:37]
            stopTime := shr(224, calldataload(add(contextData.offset, 0x25))) // bytes[37:41]
            slope := calldataload(add(contextData.offset, 0x29)) // bytes[41:73]
        }
    }
}
