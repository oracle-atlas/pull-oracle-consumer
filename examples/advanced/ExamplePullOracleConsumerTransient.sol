// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PullOracleConsumerTransient} from "src-advanced/PullOracleConsumerTransient.sol";

// When uncommenting the hook override examples below, add:
// import {IPullOracleReferenceHooks} from "interfaces/IPullOracleReferenceHooks.sol";

/**
 * @title ExamplePullOracleConsumerTransient
 * @notice Demonstrates how to integrate with the Pull Oracle SDK using the Transient consumer.
 *
 * @dev Integration Guide:
 *
 * The Transient consumer uses EIP-1153 transient storage for O(M+N) batch lookups on
 * unordered payloads (vs O(M*N) in the Standard consumer). Requires the Cancun EVM.
 *
 * IMPORTANT: Lower algorithmic complexity does NOT always translate to lower gas cost.
 * The Transient batch functions incur a fixed overhead per call (TSTORE/TLOAD setup and
 * cleanup). For small batch sizes, the Standard O(M*N) linear scan may actually consume
 * less gas due to its simpler execution path. The Transient approach becomes advantageous
 * only when the product of requested feeds (M) and payload packages (N) is large enough
 * for the O(M+N) scaling to offset the per-call setup cost. Benchmark both paths against
 * your expected workload before choosing.
 *
 * Key differences from Standard:
 *   - Transient batch functions are NOT view (TSTORE modifies transient state)
 *   - Achieves better gas scaling for large batch requests
 *   - Single-feed accessors remain view-compatible (no TSTORE)
 *
 * Available data accessor functions:
 *   - _getVerifiedFeedData(feedId)                         → single, view, reverts if missing
 *   - _getVerifiedFeedDataBatch(feedIds)                   → batch O(M*N), view, reverts if any missing
 *   - _getVerifiedFeedDataLenient(feedId)                  → single, view, returns 0 if missing
 *   - _getVerifiedFeedDataBatchLenient(feedIds)            → batch O(M*N), view, returns 0 for missing
 *   - _getVerifiedFeedDataBatchTransient(feedIds)          → batch O(M+N), non-view, reverts if any missing
 *   - _getVerifiedFeedDataBatchLenientTransient(feedIds)   → batch O(M+N), non-view, returns 0 for missing
 *
 * @custom:security When using _getVerifiedFeedDataBatchTransient or
 * _getVerifiedFeedDataBatchLenientTransient, do NOT TSTORE to feed-ID-keyed slots in the
 * same transaction. See PullOracleConsumerTransient contract-level documentation for the
 * reserved key format.
 */
contract ExamplePullOracleConsumerTransient is PullOracleConsumerTransient {
    /// @dev Example feed IDs (replace with actual feed IDs from your oracle provider)
    bytes4 internal constant FEED_A = 0x00000001;
    bytes4 internal constant FEED_B = 0x00000002;
    bytes4 internal constant FEED_C = 0x00000003;

    /// @notice Emitted when a single feed value is consumed
    event SingleFeedConsumed(bytes4 indexed feedId, uint256 price, uint256 timestamp);

    /// @notice Emitted when batch feed values are consumed via transient storage indexing
    event BatchFeedsConsumed(bytes4[] feedIds, uint256[] prices, uint256[] timestamps);

    /// @notice Emitted when a lenient single feed lookup completes (price and timestamp are 0 if absent)
    event LenientFeedConsumed(bytes4 indexed feedId, uint256 price, uint256 timestamp);

    /// @notice Emitted when a lenient batch lookup completes (entries may be 0 for absent feeds)
    event LenientBatchFeedsConsumed(bytes4[] feedIds, uint256[] prices, uint256[] timestamps);

    /* ————————————————————————————————————————————————————————————————————————
                    EXAMPLE 1: SINGLE FEED — STRICT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate single feed retrieval — identical to Standard, uses O(N) linear scan.
     * @dev Single-feed functions do NOT use transient storage and remain view-compatible.
     * Reverts if the feed ID is missing from the payload, signature is invalid, or
     * timestamp fails freshness validation.
     */
    function exampleSingleFeed() external {
        (uint256 price, uint256 timestamp) = _getVerifiedFeedData(FEED_A);

        emit SingleFeedConsumed(FEED_A, price, timestamp);

        // Add your business logic here, e.g.:
        // - Store the price for on-chain reference
        // - Trigger settlement or liquidation based on price thresholds
        // - Update internal accounting with the verified timestamp
    }

    /* ————————————————————————————————————————————————————————————————————————
                    EXAMPLE 2: SINGLE FEED — LENIENT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate single feed retrieval with graceful handling of missing feeds.
     * @dev Returns (0, 0) instead of reverting when the feed ID is absent from the payload.
     * Single-feed lenient is also view-compatible (no TSTORE).
     */
    function exampleSingleFeedLenient() external {
        (uint256 price, uint256 timestamp) = _getVerifiedFeedDataLenient(FEED_A);

        emit LenientFeedConsumed(FEED_A, price, timestamp);

        // Add your business logic here, e.g.:
        // - Fall back to a cached price or secondary oracle when unavailable
        // - Skip optional fee calculations when the auxiliary feed is absent
    }

    /* ————————————————————————————————————————————————————————————————————————
                    EXAMPLE 3: BATCH FEEDS — O(M*N) LINEAR SCAN (STRICT)
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate batch retrieval using the base O(M*N) linear scan (strict mode).
     * @dev View-compatible (no TSTORE). Suitable for small batch sizes where the O(M*N)
     * overhead is acceptable and view/staticcall compatibility is required.
     * Reverts if ANY requested feed ID is missing.
     */
    function exampleBatchFeeds() external {
        bytes4[] memory feedIds = new bytes4[](3);
        feedIds[0] = FEED_A;
        feedIds[1] = FEED_B;
        feedIds[2] = FEED_C;

        (uint256[] memory prices, uint256[] memory timestamps) = _getVerifiedFeedDataBatch(feedIds);

        emit BatchFeedsConsumed(feedIds, prices, timestamps);

        // Add your business logic here, e.g.:
        // - Compute cross-asset ratios or composite indices
        // - Perform multi-collateral valuation in a single transaction
        // - Settle a batch of orders against their respective price feeds
    }

    /* ————————————————————————————————————————————————————————————————————————
                    EXAMPLE 4: BATCH FEEDS — O(M*N) LINEAR SCAN (LENIENT)
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate batch retrieval using the base O(M*N) linear scan (lenient mode).
     * @dev View-compatible (no TSTORE). Returns (0, 0) for missing feeds without reverting.
     */
    function exampleBatchFeedsLenient() external {
        bytes4[] memory feedIds = new bytes4[](3);
        feedIds[0] = FEED_A;
        feedIds[1] = FEED_B;
        feedIds[2] = FEED_C;

        (uint256[] memory prices, uint256[] memory timestamps) = _getVerifiedFeedDataBatchLenient(feedIds);

        emit LenientBatchFeedsConsumed(feedIds, prices, timestamps);

        // Add your business logic here, e.g.:
        // - Process only feeds with non-zero prices, skipping unavailable ones
        // - Aggregate partial price data for best-effort portfolio valuation
    }

    /* ————————————————————————————————————————————————————————————————————————
          EXAMPLE 5: BATCH FEEDS — O(M+N) VIA TRANSIENT STORAGE (STRICT)
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate transient-optimized batch retrieval (strict mode).
     * @dev O(M+N) complexity — significantly cheaper than Standard for large feed sets.
     * NOT a view function due to internal TSTORE operations. Reverts if ANY requested
     * feed ID is missing.
     */
    function exampleBatchTransient() external {
        bytes4[] memory feedIds = new bytes4[](3);
        feedIds[0] = FEED_A;
        feedIds[1] = FEED_B;
        feedIds[2] = FEED_C;

        (uint256[] memory prices, uint256[] memory timestamps) = _getVerifiedFeedDataBatchTransient(feedIds);

        emit BatchFeedsConsumed(feedIds, prices, timestamps);

        // Add your business logic here, e.g.:
        // - Compute cross-asset ratios or composite indices
        // - Perform multi-collateral valuation in a single transaction
        // - Settle a batch of orders against their respective price feeds
    }

    /* ————————————————————————————————————————————————————————————————————————
          EXAMPLE 6: BATCH FEEDS — O(M+N) VIA TRANSIENT STORAGE (LENIENT)
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate lenient batch retrieval with zero-fill for missing feeds.
     * @dev Does not revert on missing feeds — indices with absent feed IDs return (0, 0).
     * NOT a view function due to internal TSTORE operations.
     */
    function exampleBatchTransientLenient() external {
        bytes4[] memory feedIds = new bytes4[](3);
        feedIds[0] = FEED_A;
        feedIds[1] = FEED_B;
        feedIds[2] = FEED_C;

        (uint256[] memory prices, uint256[] memory timestamps) = _getVerifiedFeedDataBatchLenientTransient(feedIds);

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
    //
    // See ExamplePullOracleConsumerStandard.sol for the full set of override examples.

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
