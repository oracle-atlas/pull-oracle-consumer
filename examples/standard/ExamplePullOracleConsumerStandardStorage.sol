// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {PullOracleConsumerStandardStorage} from "src/PullOracleConsumerStandardStorage.sol";

/**
 * @title ExamplePullOracleConsumerStandardStorage
 * @notice Demonstrates how to integrate with the Pull Oracle SDK using the Storage-backed consumer.
 *
 * @dev Integration Guide:
 *
 * This variant stores all configuration in contract storage, enabling runtime governance:
 *   - Signer rotation without redeployment
 *   - Adjustable timestamp thresholds
 *   - Dynamic package count limits
 *
 * Tradeoff: Each hook invocation incurs SLOAD gas cost (~100 gas warm, ~2100 gas cold)
 * compared to the zero-overhead hardcoded approach in PullOracleConsumerStandard.
 *
 * Constructor parameters:
 *   - maxPackageCount: Maximum feeds per call (uint8, must be > 0)
 *   - maxDelay: Staleness tolerance in seconds (uint48, must be > 0)
 *   - maxFutureDrift: Future drift tolerance in seconds (uint48, 0 = strict)
 *   - initialSigners: Initial authorized signer addresses (can be empty for two-step deploy)
 *
 * Internal setters (gate behind access control in your subclass):
 *   - _setMaxPackageCount(uint8)
 *   - _setMaxDelay(uint48)
 *   - _setMaxFutureDrift(uint48)
 *   - _setSignerStatus(address, bool)
 *
 * Available data accessor functions (inherited from PullOracleConsumerBase):
 *   - _getVerifiedFeedData(feedId)              → single feed, reverts if missing
 *   - _getVerifiedFeedDataBatch(feedIds)        → multi feed, reverts if any missing
 *   - _getVerifiedFeedDataLenient(feedId)       → single feed, returns 0 if missing
 *   - _getVerifiedFeedDataBatchLenient(feedIds) → multi feed, returns 0 for missing
 */
contract ExamplePullOracleConsumerStandardStorage is PullOracleConsumerStandardStorage {
    address public owner;

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() private view {
        require(msg.sender == owner, "Not owner");
    }

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
                                  CONSTRUCTOR
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Initialize with example configuration values.
     * These parameters are illustrative only — integrators MUST determine appropriate
     * values based on their protocol's latency tolerance, security model, and operational
     * requirements before deploying to production.
     * @param initialSigners Array of authorized oracle signer addresses. Refer to the
     * official documentation or the PullOracleReferenceHooks.isAuthorizedSigner implementation
     * for the current production signing address.
     */
    constructor(
        address[] memory initialSigners
    )
        PullOracleConsumerStandardStorage(
            255, // maxPackageCount: allow up to 255 feeds per call
            180, // maxDelay: reject prices older than 180 seconds
            60, // maxFutureDrift: reject prices more than 60 seconds in the future
            initialSigners
        )
    {
        owner = msg.sender;
    }

    /* ————————————————————————————————————————————————————————————————————————
                    EXAMPLE 1: SINGLE FEED — STRICT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate single feed retrieval with storage-backed configuration.
     * @dev The signer, delay, and drift parameters are read from storage at runtime.
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
                    EXAMPLE 2: BATCH FEEDS — STRICT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Demonstrate batch feed retrieval with storage-backed configuration.
     * @dev Reverts if ANY requested feed ID is missing. More gas-efficient than multiple
     * single calls due to shared signature verification.
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

        emit LenientBatchFeedsConsumed(feedIds, prices, timestamps);

        // Add your business logic here, e.g.:
        // - Process only feeds with non-zero prices, skipping unavailable ones
        // - Aggregate partial price data for best-effort portfolio valuation
    }

    /* ————————————————————————————————————————————————————————————————————————
                          GOVERNANCE SETTER EXAMPLES
    ————————————————————————————————————————————————————————————————————————— */

    // The Storage-backed consumer exposes internal setters for all configuration
    // parameters. Gate these behind your protocol's access control (e.g., OpenZeppelin
    // Ownable, AccessControl, or a timelock) to enable runtime governance without
    // redeployment.

    /// @notice Rotate or add an authorized signer.
    function setSignerStatus(address signer, bool status) external onlyOwner {
        _setSignerStatus(signer, status);
    }

    /// @notice Update the staleness threshold.
    function setMaxDelay(uint48 newMaxDelay) external onlyOwner {
        _setMaxDelay(newMaxDelay);
    }

    /// @notice Update the future drift tolerance.
    function setMaxFutureDrift(uint48 newMaxFutureDrift) external onlyOwner {
        _setMaxFutureDrift(newMaxFutureDrift);
    }

    /// @notice Update the maximum package count per call.
    function setMaxPackageCount(uint8 newMaxPackageCount) external onlyOwner {
        _setMaxPackageCount(newMaxPackageCount);
    }
}
