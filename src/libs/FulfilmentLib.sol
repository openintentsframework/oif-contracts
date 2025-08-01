

library FulfilmentLib {
    bytes1 constant LIMIT_ORDER = 0x00;
    bytes1 constant DUTCH_AUCTION = 0x01;
    bytes1 constant EXCLUSIVE_LIMIT_ORDER = 0xe0;
    bytes1 constant EXCLUSIVE_DUTCH_AUCTION = 0xe1;

    error InvalidContextDataLength();

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