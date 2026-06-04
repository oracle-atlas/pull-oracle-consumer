// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {
    FOOTER_SIZE,
    FEED_PACKAGE_SIZE,
    MARKER_SIZE,
    LEFT_SHIFTED_MAGIC_MARKER,
    MIN_CALLDATA_SIZE,
    SELECTOR_SIZE
} from "constants/Constants.sol";

/**
 * @title PullOracleCodec
 * @notice High-performance bitwise codec for Pull Oracle protocol
 * @dev Engineered with inline assembly to achieve gas-optimized data extraction
 * Key optimizations:
 * - Suffix-based parsing to maintain compatibility with arbitrary business calldata
 * - XOR-based magic marker validation exploiting calldata zero-padding
 * - Precision bitwise slicing to extract 80-bit prices and 48-bit timestamps
 * - Memory-safe assembly blocks with direct error selector mstore for minimal gas
 */
library PullOracleCodec {
    // Pre-computed error selector for `error InsufficientMetadata()`
    bytes4 internal constant INSUFFICIENT_METADATA_SELECTOR = 0xfec99f4b;
    // Pre-computed error selector for `error InvalidMarker()`
    bytes4 internal constant INVALID_MARKER_SELECTOR = 0x86c92a85;
    // Pre-computed error selector for `error ZeroPackageCount()`
    bytes4 internal constant ZERO_PACKAGE_COUNT_SELECTOR = 0xa71e4f6f;
    // Pre-computed error selector for `error ExceedsMaxPackageCount(uint256,uint256)`
    bytes4 internal constant EXCEEDS_MAX_COUNT_SELECTOR = 0x59acf197;
    // Pre-computed error selector for `error InsufficientFeedPackages()`
    bytes4 internal constant INSUFFICIENT_FEED_PACKAGES_SELECTOR = 0x0d6e4e63;

    /**
     * @notice Parse protocol metadata and calculate pointer offsets
     * @param maxPackageCount The safety threshold defined by the consumer contract
     * @return payloadStart Byte offset where the first FeedData package begins
     * @return payloadEnd Byte offset immediately after the last FeedData package
     * @dev Guaranteed invariant: payloadStart < payloadEnd, since count >= 1
     * and the span is count * FEED_PACKAGE_SIZE (minimum 20 bytes).
     */
    function _parseMetadata(uint256 maxPackageCount) internal pure returns (uint256 payloadStart, uint256 payloadEnd) {
        assembly ("memory-safe") {
            // Verify calldata is at least long enough to contain the selector, one package, and the footer
            if lt(calldatasize(), MIN_CALLDATA_SIZE) {
                mstore(0x00, INSUFFICIENT_METADATA_SELECTOR)
                revert(0x00, 0x04)
            }

            // Validate the magic marker with minimal gas by exploiting calldata zero-padding and XOR
            if xor(calldataload(sub(calldatasize(), MARKER_SIZE)), LEFT_SHIFTED_MAGIC_MARKER) {
                mstore(0x00, INVALID_MARKER_SELECTOR)
                revert(0x00, 0x04)
            }

            payloadEnd := sub(calldatasize(), FOOTER_SIZE)

            // Locate and read the package count from the metadata
            let count := byte(0, calldataload(payloadEnd))

            // Revert if no packages are provided to prevent invalid state updates
            if iszero(count) {
                mstore(0x00, ZERO_PACKAGE_COUNT_SELECTOR)
                revert(0x00, 0x04)
            }

            // Enforce security boundaries by checking package count against the allowed maximum
            if gt(count, maxPackageCount) {
                mstore(0x00, EXCEEDS_MAX_COUNT_SELECTOR)
                mstore(0x04, count)
                mstore(0x24, maxPackageCount)
                revert(0x00, 0x44)
            }

            // Ensure calldata is long enough to contain at least the selector and oracle suffix
            let extraDataSize := add(mul(count, FEED_PACKAGE_SIZE), FOOTER_SIZE)
            // This is the minimum generic check. Business argument overlap is handled by signature mismatch
            if lt(calldatasize(), add(extraDataSize, SELECTOR_SIZE)) {
                mstore(0x00, INSUFFICIENT_FEED_PACKAGES_SELECTOR)
                revert(0x00, 0x04)
            }

            payloadStart := sub(calldatasize(), extraDataSize)
        }
    }

    /**
     * @notice Extract price and aggregated timestamp from a pre-loaded calldata word
     * @dev Process stack-allocated word to minimize redundant calldataload operations
     * @param packageWordByCalldataload The 32-byte word from calldata [Feed ID][Price][Time][Trailing Junk]
     * @return price Decoded from the middle 10 bytes
     * @return aggregatedTimestamp Decoded from the trailing 6 bytes
     */
    function _parseFeedPackage(
        bytes32 packageWordByCalldataload
    ) internal pure returns (uint256 price, uint256 aggregatedTimestamp) {
        assembly ("memory-safe") {
            // Strip Feed ID and junk to result in layout: [0...0][Price 80b][Time 48b]
            let packed := shr(128, shl(32, packageWordByCalldataload))

            // Extract price by shifting out the 48-bit timestamp
            price := shr(48, packed)

            // Extract timestamp using 48-bit mask
            aggregatedTimestamp := and(packed, 0xffffffffffff)
        }
    }
}
