// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {PullOracleConsumerStandard} from "src/PullOracleConsumerStandard.sol";

// When uncommenting the hook override examples below, add:
// import {IPullOracleReferenceHooks} from "interfaces/IPullOracleReferenceHooks.sol";

/**
 * @title ExamplePullOracleConsumerStandard
 * @notice Demonstrates how to integrate with the Pull Oracle SDK using the Standard consumer.
 *
 * @dev Integration Guide:
 *
 * 1. MINIMAL INTEGRATION (use reference hooks as-is):
 *    Simply inherit PullOracleConsumerStandard and call the internal data accessors.
 *    The reference hooks from PullOracleReferenceHooks provide:
 *      - Authorized signer: Atlas Oracle official signing key
 *      - Max delay: 180 seconds
 *      - Max future drift: 60 seconds
 *      - Max package count: 255
 *
 * 2. CUSTOM HOOKS (override for protocol-specific requirements):
 *    Override _validateTimestamp, _getMaxPackageCount, or _isAuthorizedSigner
 *    to tailor validation to your protocol's security model. All hooks remain
 *    hardcoded (no SLOAD) for maximum gas efficiency.
 *
 * Available data accessor functions (inherited from PullOracleConsumerBase):
 *   - _getVerifiedFeedData(feedId)              → single feed, reverts if missing
 *   - _getVerifiedFeedDataBatch(feedIds)        → multi feed, reverts if any missing
 *   - _getVerifiedFeedDataLenient(feedId)       → single feed, returns 0 if missing
 *   - _getVerifiedFeedDataBatchLenient(feedIds) → multi feed, returns 0 for missing
 */
contract ExamplePullOracleConsumerStandard is PullOracleConsumerStandard {
    /// @dev Example feed IDs (replace with actual feed IDs from your oracle provider)
    bytes4 internal constant FEED_A = 0x00000001;
    bytes4 internal constant FEED_B = 0x00000002;
    bytes4 internal constant FEED_C = 0x00000003;

    /// @notice Emitted when a single feed value is consumed
    event SingleFeedConsumed(bytes4 indexed feedId, uint256 price, uint256 timestamp);

    /// @notice Emitted when multiple feed values are consumed in a batch
    event BatchFeedsConsumed(bytes4[] feedIds, uint256[] prices, uint256[] timestamps);

    /// @notice Emitted when a lenient single feed lookup completes (price and timestamp are 0 if absent)
    event LenientFeedConsumed(bytes4 indexed feedId, uint256 price, uint256 timestamp);

    /// @notice Emitted when a lenient batch lookup completes (entries may be 0 for absent feeds)
    event LenientBatchFeedsConsumed(bytes4[] feedIds, uint256[] prices, uint256[] timestamps);

    /* ————————————————————————————————————————————————————————————————————————
                    EXAMPLE 1: SINGLE FEED — STRICT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate retrieving and consuming a single verified feed value.
     * @dev Reverts if the feed ID is missing from the payload, signature is invalid, or
     * timestamp fails freshness validation.
     */
    function exampleSingleFeed() external {
        (uint256 price, uint256 timestamp) = _getVerifiedFeedData(FEED_A);

        // Use both return values in your business logic
        emit SingleFeedConsumed(FEED_A, price, timestamp);

        // Add your business logic here, e.g.:
        // - Store the price for on-chain reference
        // - Trigger settlement or liquidation based on price thresholds
        // - Update internal accounting with the verified timestamp
    }

    /* ————————————————————————————————————————————————————————————————————————
                    EXAMPLE 2: BATCH FEEDS — STRICT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate retrieving and consuming multiple verified feed values.
     * @dev Reverts if ANY requested feed ID is missing. More gas-efficient than multiple
     * single calls due to shared signature verification.
     */
    function exampleBatchFeeds() external {
        bytes4[] memory feedIds = new bytes4[](3);
        feedIds[0] = FEED_A;
        feedIds[1] = FEED_B;
        feedIds[2] = FEED_C;

        (uint256[] memory prices, uint256[] memory timestamps) = _getVerifiedFeedDataBatch(feedIds);

        // All return values are available for business logic
        emit BatchFeedsConsumed(feedIds, prices, timestamps);

        // Add your business logic here, e.g.:
        // - Compute cross-asset ratios or composite indices
        // - Perform multi-collateral valuation in a single transaction
        // - Settle a batch of orders against their respective price feeds
    }

    /* ————————————————————————————————————————————————————————————————————————
                    EXAMPLE 3: SINGLE FEED — LENIENT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate retrieving a feed value with graceful handling of missing feeds.
     * @dev Returns (0, 0) instead of reverting when the feed ID is absent from the payload.
     * Useful when the feed may not always be included.
     */
    function exampleSingleFeedLenient() external {
        (uint256 price, uint256 timestamp) = _getVerifiedFeedDataLenient(FEED_A);

        emit LenientFeedConsumed(FEED_A, price, timestamp);

        // Add your business logic here, e.g.:
        // - Fall back to a cached price or secondary oracle when unavailable
        // - Skip optional fee calculations when the auxiliary feed is absent
    }

    /* ————————————————————————————————————————————————————————————————————————
                    EXAMPLE 4: BATCH FEEDS — LENIENT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate batch retrieval with zero-fill for missing feeds.
     * @dev Does not revert on missing feeds — indices with absent feed IDs return (0, 0).
     * Caller is responsible for interpreting zero values.
     */
    function exampleBatchFeedsLenient() external {
        bytes4[] memory feedIds = new bytes4[](3);
        feedIds[0] = FEED_A;
        feedIds[1] = FEED_B;
        feedIds[2] = FEED_C;

        (uint256[] memory prices, uint256[] memory timestamps) = _getVerifiedFeedDataBatchLenient(feedIds);

        // Zero entries indicate feeds not present in the payload
        emit LenientBatchFeedsConsumed(feedIds, prices, timestamps);

        // Add your business logic here, e.g.:
        // - Process only feeds with non-zero prices, skipping unavailable ones
        // - Aggregate partial price data for best-effort portfolio valuation
    }

    /* ————————————————————————————————————————————————————————————————————————
                            HOOK OVERRIDE EXAMPLES
    ————————————————————————————————————————————————————————————————————————— */

    // PullOracleReferenceHooks ships with sensible defaults (180s max delay, 60s max
    // future drift, 255 max packages, and the official Atlas Oracle signer). If your
    // protocol's security model or operational requirements differ from these reference
    // parameters, override the corresponding hook function(s) below.
    //
    // Each override remains a pure compile-time constant (no SLOAD), preserving the
    // gas-efficiency guarantee of the hardcoded consumer. For runtime-configurable
    // parameters, use the Storage-backed consumer variant instead.

    /*
    /// @dev Example: Tighten the freshness requirement to 60 seconds.
    function _validateTimestamp(bytes4 feedId, uint256 parsedAggregateTimestamp) internal view override {
        unchecked {
            if (block.timestamp >= parsedAggregateTimestamp) {
                if (block.timestamp - parsedAggregateTimestamp > 60) {
                    revert IPullOracleReferenceHooks.PriceFeedExpired(feedId, parsedAggregateTimestamp, block.timestamp);
                }
            } else if (parsedAggregateTimestamp - block.timestamp > 30) {
                revert IPullOracleReferenceHooks.PriceFeedFutureDrift(feedId, parsedAggregateTimestamp, block.timestamp);
            }
        }
    }

    /// @dev Example: Limit to 10 packages per call for gas-sensitive contexts.
    function _getMaxPackageCount() internal view override returns (uint256) {
        return 10;
    }

    /// @dev Example: If the signing address published in the official documentation does
    /// not match the one hardcoded in PullOracleReferenceHooks, override as follows.
    function _isAuthorizedSigner(address recoveredSigner) internal view override returns (bool) {
        return recoveredSigner == 0x1234567890AbcdEF1234567890aBcdef12345678;
    }
    */
}
