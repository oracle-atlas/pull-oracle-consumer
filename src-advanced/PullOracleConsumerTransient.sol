// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PullOracleCodec} from "src/libraries/PullOracleCodec.sol";
import {FEED_PACKAGE_SIZE, FEED_ID_MASK} from "src/constants/Constants.sol";
import {PullOracleReferenceHooks} from "src/libraries/PullOracleReferenceHooks.sol";
import {PullOracleConsumerBase} from "src/base/PullOracleConsumerBase.sol";

/**
 * @title PullOracleConsumerTransient
 * @notice Transient storage optimized consumer with reference hook implementations from PullOracleReferenceHooks
 * @dev Utilize EIP-1153 opcodes to achieve O(M+N) complexity on unordered payloads.
 * @dev This contract provides a reusable indexing mechanism via transient storage.
 *
 * IMPORTANT: Integrators MUST review the trust assumptions documented in PullOracleReferenceHooks
 * before deploying. The hardcoded values serve as reference defaults for the Atlas Oracle integration
 * and may not be appropriate for all deployment scenarios. If your protocol requires tighter
 * freshness bounds or custom package limits, override the corresponding hook(s) in your
 * subclass. Alternatively, inherit from PullOracleConsumerTransientStorage for runtime
 * configurability via storage-backed setters.
 *
 * The official production signing address is hardcoded in PullOracleReferenceHooks.isAuthorizedSigner.
 *
 * The tradeoff is immutability — modifying any of these values post-deployment requires a
 * contract upgrade. If runtime configurability is preferred over gas optimization, inherit
 * from PullOracleConsumerTransientStorage instead, which provides a storage-backed registry
 * with governance-controlled signer rotation, adjustable timestamp thresholds, and dynamic
 * package count limits.
 *
 * @custom:security If your contract uses _getVerifiedFeedDataBatchTransient or
 * _getVerifiedFeedDataBatchLenientTransient, you MUST NOT perform any TSTORE operations
 * to slots derived from feed ID values within the same transaction. These functions use
 * feed-ID-keyed transient slots as an ephemeral lookup cache; any foreign writes to the
 * same key space may be misinterpreted as valid oracle data.
 *
 * Reserved transient slot key space:
 *   key = bytes4 feedId stored as a native bytes32 (left-aligned, zero-padded).
 *   Example: feedId 0xAABBCCDD
 *            → key  0xAABBCCDD00000000000000000000000000000000000000000000000000000000
 *
 * Any TSTORE to a key in this form within the same transaction will conflict with the
 * oracle lookup cache. Inheriting contracts that use EIP-1153 for other purposes must
 * ensure their key derivation does not produce values in this range.
 */
abstract contract PullOracleConsumerTransient is PullOracleConsumerBase {
    using PullOracleCodec for bytes32;

    /* ————————————————————————————————————————————————————————————————————————
                            INTERNAL API: DATA ACCESSORS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Batch retrieve multiple cryptographically verified feed values.
     * @notice This function utilizes EIP-1153 transient storage to achieve superior
     * performance on large unordered payloads.
     * @dev Performance: O(M+N)
     * @dev Note that this function is not 'view' and does not 'override' the base
     * implementation because 'TSTORE' is a state-modifying operation. It cannot
     * be used in 'staticcall' contexts.
     * @custom:security This function temporarily occupies transient storage slots keyed by
     * feed ID during execution. If the same slots already contain non-zero values from prior
     * TSTORE operations in the current transaction, those values may be incorrectly decoded
     * as signed oracle packages, bypassing payload authenticity guarantees. Refer to the
     * contract-level security documentation for the reserved key format specification.
     * @param feedIds An array of 4-byte feed identifiers. For maximum flexibility, an empty
     *        array is not rejected — it short-circuits before authentication and returns
     *        empty result arrays. Duplicate entries are permitted and no deduplication is
     *        performed; each element is resolved independently.
     * @return prices An array of verified prices in the requested order
     * @return aggregatedTimestamps Off-chain aggregated timestamps
     * @custom:reverts UnmatchedFeedID If any requested feed ID is missing from the signed payload
     * @custom:reverts _validateTimestamp Reverts if any aggregatedTimestamp fails validity criteria
     */
    function _getVerifiedFeedDataBatchTransient(
        bytes4[] memory feedIds
    ) internal virtual returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        if (feedIds.length == 0) return (prices, aggregatedTimestamps);

        // Authenticate identity and unpack layout from trailing extra data
        (uint256 payloadStart, uint256 payloadEnd) = _authenticateAndUnpackExtraData();

        // Process bulk request and enforce presence of all requested feeds using transient index
        return
            _getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(
                feedIds,
                payloadStart,
                payloadEnd
            );
    }

    /**
     * @notice Batch retrieve multiple verified feeds with zero-initialization for missing IDs.
     * @notice Missing feed IDs in the payload will result in (0, 0) values in the output arrays.
     * @dev Performance: O(M+N)
     * @dev Ensures the call does not revert solely due to missing feeds in the payload.
     * @dev This implementation is optimized for high-volume batch requests where the
     * underlying data layout in extra data is unknown or unordered. Like its strict
     * counterpart, this function requires the 'cancun' EVM and is not 'view' compatible.
     * @custom:security This function temporarily occupies transient storage slots keyed by
     * feed ID during execution. If the same slots already contain non-zero values from prior
     * TSTORE operations in the current transaction, those values may be incorrectly decoded
     * as signed oracle packages, bypassing payload authenticity guarantees. Refer to the
     * contract-level security documentation for the reserved key format specification.
     * @param feedIds An array of 4-byte feed identifiers. For maximum flexibility, an empty
     *        array is not rejected — it short-circuits before authentication and returns
     *        empty result arrays. Duplicate entries are permitted and no deduplication is
     *        performed; each element is resolved independently.
     * @return prices Arrays containing verified prices or 0 for missing feeds
     * @return aggregatedTimestamps Off-chain aggregated timestamps or 0
     * @custom:reverts _validateTimestamp Reverts if any aggregatedTimestamp fails validity criteria
     */
    function _getVerifiedFeedDataBatchLenientTransient(
        bytes4[] memory feedIds
    ) internal virtual returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        if (feedIds.length == 0) return (prices, aggregatedTimestamps);

        // Authenticate identity and unpack layout from trailing extra data
        (uint256 payloadStart, uint256 payloadEnd) = _authenticateAndUnpackExtraData();

        // Fill results with verified data or zeros using the optimized transient storage lookup
        return _getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(feedIds, payloadStart, payloadEnd);
    }

    /* ————————————————————————————————————————————————————————————————————————
                                TRANSIENT STORAGE HOOKS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Execute batch lookup where any missing ID triggers a transaction revert.
     * @dev Performance: O(M+N)
     * @dev Note that O(M+N) complexity does not inherently guarantee lower gas than
     * O(M*N) linear scans due to the high constant cost of transient storage opcodes.
     * Each feed package requires a TSTORE (cache) + TLOAD (lookup) + TSTORE (clear)
     * costing 300 gas total, while a CALLDATALOAD costs only 3 gas.
     * In scenarios with small payloads, the fixed overhead of caching every package may
     * exceed the total cost of multiple linear passes used in the Standard implementation.
     * @dev This function does not 'override' the base implementation from PullOracleConsumerBase
     * because the base function is defined as 'view' to ensure compatibility with static calls.
     * This implementation uses EIP-1153 'TSTORE', which is considered a state-modifying
     * operation. Since a non-view function cannot override a view function, this version
     * is provided as a standalone high-performance alternative.
     * @dev Precondition: payloadStart < payloadEnd is guaranteed by _parseMetadata
     * (count >= 1, span >= FEED_PACKAGE_SIZE). Not re-checked here for gas optimization.
     * @param feedIds Array of 4-byte feed IDs to locate
     * @param payloadStart Byte offset where the first feed package begins in the calldata
     * @param payloadEnd Byte offset immediately after the last feed package in the calldata
     * @return prices Array of decoded prices in the same order as feedIds
     * @return aggregatedTimestamps Array of decoded timestamps in the same order as feedIds
     * @custom:reverts UnmatchedFeedID If any requested feed ID is missing from the signed payload
     * @custom:reverts _validateTimestamp Reverts if any aggregatedTimestamp fails the implementation-specific validity or freshness criteria
     */
    function _getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(
        bytes4[] memory feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) internal returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        // Cache array length to stack to avoid redundant mload operations
        uint256 requestLen = feedIds.length;
        uint256 ptrFeedIds;
        uint256 ptrPrices;
        uint256 ptrAggregatedTimestamps;
        uint256 feedIdsEnd;

        // Bypass standard `new uint256[]` allocation to skip redundant zero-initialization gas overhead
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            // Calculate size for [length word (32B) + data (requestLen * 32B)]
            let arraySize := shl(5, add(requestLen, 1))

            // Allocate prices array header and move pointer
            prices := fmp
            mstore(prices, requestLen)

            // Allocate aggregatedTimestamps array header immediately following the prices array
            aggregatedTimestamps := add(fmp, arraySize)
            mstore(aggregatedTimestamps, requestLen)

            // Update the global free memory pointer for both allocations to prevent collision
            mstore(0x40, add(aggregatedTimestamps, arraySize))

            // Set initial pointers to first elements skipping array length words
            ptrFeedIds := add(feedIds, 32)
            ptrPrices := add(prices, 32)
            ptrAggregatedTimestamps := add(aggregatedTimestamps, 32)

            // Define the termination pointer for the feed ID input array based on request length
            feedIdsEnd := add(ptrFeedIds, shl(5, requestLen))
        }

        // Cache all packages into transient storage to enable O(1) lookups
        _cacheFeedPackagesToTransientStorage(payloadStart, payloadEnd);

        // Using for(;;) + tail break as a do-while idiom: the caller guarantees
        // feedIds.length > 0, so the first iteration is unconditional.
        for (;;) {
            bytes32 word;
            bytes4 targetFeedId;

            assembly ("memory-safe") {
                targetFeedId := mload(ptrFeedIds)
                // Fetch data from transient storage
                word := tload(targetFeedId)

                // Validate: a non-zero word must belong to the current signed payload.
                // Legitimate cache entries have the feed ID in the high 4 bytes.
                // If the high 4 bytes do not match, the slot contains foreign
                // transient data written by other logic — treat as unmatched.
                if iszero(eq(and(word, FEED_ID_MASK), targetFeedId)) {
                    word := 0
                }

                // Revert if the requested feedId is missing from the cached index
                if iszero(word) {
                    mstore(0x00, UNMATCHED_FEED_ID_SELECTOR)
                    // Store the missing feedId directly (bytes4 is already left-aligned)
                    mstore(0x04, targetFeedId)
                    revert(0x00, 0x24)
                }
            }

            // Decode the found word using the bitwise codec library
            (uint256 price, uint256 aggregatedTimestamp) = word._parseFeedPackage();
            // Execute timestamp validity check which may revert internally on invalid values
            _validateTimestamp(targetFeedId, aggregatedTimestamp);

            // Write results and advance all memory pointers to the next memory slot
            assembly ("memory-safe") {
                // Store validated results directly to pre-allocated memory slots
                mstore(ptrPrices, price)
                mstore(ptrAggregatedTimestamps, aggregatedTimestamp)

                // Increment all pointers by one word to the next array index
                ptrFeedIds := add(ptrFeedIds, 32)
                ptrPrices := add(ptrPrices, 32)
                ptrAggregatedTimestamps := add(ptrAggregatedTimestamps, 32)
            }

            if (ptrFeedIds >= feedIdsEnd) break;
        }

        // Clear all cached slots to prevent stale data from leaking into subsequent calls
        // within the same transaction
        _clearTransientCache(payloadStart, payloadEnd);
    }

    /**
     * @dev Execute batch lookup where missing IDs return zero instead of reverting.
     * @dev Performance: O(M+N).
     * @dev Note that O(M+N) complexity does not inherently guarantee lower gas than
     * O(M*N) linear scans due to the high constant cost of transient storage opcodes.
     * Each feed package requires a TSTORE (cache) + TLOAD (lookup) + TSTORE (clear)
     * costing 300 gas total, while a CALLDATALOAD costs only 3 gas.
     * In scenarios with small payloads, the fixed overhead of caching every package may
     * exceed the total cost of multiple linear passes used in the Standard implementation.
     * @dev This function does not 'override' the base implementation because the base
     * function is defined as 'view'. This implementation uses EIP-1153 'TSTORE',
     * which is a state-modifying operation. Since a non-view function cannot override
     * a view function, this version is provided as a standalone high-performance alternative.
     * @dev Precondition: payloadStart < payloadEnd is guaranteed by _parseMetadata
     * (count >= 1, span >= FEED_PACKAGE_SIZE). Not re-checked here for gas optimization.
     * @param feedIds Array of 4-byte feed IDs to locate
     * @param payloadStart Byte offset where the first feed package begins in the calldata
     * @param payloadEnd Byte offset immediately after the last feed package in the calldata
     * @return prices Array of decoded prices or zero if unmatched
     * @return aggregatedTimestamps Array of decoded timestamps or zero if unmatched
     * @custom:reverts _validateTimestamp Reverts if any aggregatedTimestamp fails validity criteria
     */
    function _getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(
        bytes4[] memory feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) internal returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        // Cache array length to stack to avoid redundant mload operations
        uint256 requestLen = feedIds.length;
        uint256 ptrFeedIds;
        uint256 ptrPrices;
        uint256 ptrAggregatedTimestamps;
        uint256 feedIdsEnd;

        // Bypass standard `new uint256[]` allocation to skip redundant zero-initialization gas overhead
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            // Calculate size for [length word (32B) + data (requestLen * 32B)]
            let arraySize := shl(5, add(requestLen, 1))

            // Allocate prices array header and move pointer
            prices := fmp
            mstore(prices, requestLen)

            // Allocate aggregatedTimestamps array header immediately following the prices array
            aggregatedTimestamps := add(fmp, arraySize)
            mstore(aggregatedTimestamps, requestLen)

            // Update the global free memory pointer for both allocations to prevent collision
            mstore(0x40, add(aggregatedTimestamps, arraySize))

            // Set initial pointers to first elements skipping array length words
            ptrFeedIds := add(feedIds, 32)
            ptrPrices := add(prices, 32)
            ptrAggregatedTimestamps := add(aggregatedTimestamps, 32)

            // Define the termination pointer for the feed ID input array based on request length
            feedIdsEnd := add(ptrFeedIds, shl(5, requestLen))
        }

        // Cache all packages into transient storage to enable O(1) lookups
        _cacheFeedPackagesToTransientStorage(payloadStart, payloadEnd);

        // Iterate through requested IDs using pointer boundaries
        // Using for(;;) + tail break as a do-while idiom: the caller guarantees
        // feedIds.length > 0, so the first iteration is unconditional.
        for (;;) {
            bytes32 word;
            bytes4 targetFeedId;
            uint256 price;
            uint256 aggregatedTimestamp;

            // Fetch target feed ID and attempt O(1) transient lookup
            assembly ("memory-safe") {
                targetFeedId := mload(ptrFeedIds)
                word := tload(targetFeedId)

                // Validate: a non-zero word must belong to the current signed payload.
                // Legitimate cache entries have the feed ID in the high 4 bytes.
                // If the high 4 bytes do not match, the slot contains foreign
                // transient data written by other logic — treat as unmatched.
                if iszero(eq(and(word, FEED_ID_MASK), targetFeedId)) {
                    word := 0
                }
            }

            // Decode and validate only if a matching package exists in the cache
            if (word != bytes32(0)) {
                (price, aggregatedTimestamp) = word._parseFeedPackage();

                // Execute timestamp validity check which may revert internally on invalid values
                _validateTimestamp(targetFeedId, aggregatedTimestamp);
            }

            // Write results and advance all memory pointers to the next memory slot
            // Ensure dirty memory slots are overwritten with either validated values or zeros
            assembly ("memory-safe") {
                // Store results directly to pre-allocated memory slots
                mstore(ptrPrices, price)
                mstore(ptrAggregatedTimestamps, aggregatedTimestamp)

                // Increment all pointers by one word to the next array index
                ptrFeedIds := add(ptrFeedIds, 32)
                ptrPrices := add(ptrPrices, 32)
                ptrAggregatedTimestamps := add(ptrAggregatedTimestamps, 32)
            }

            if (ptrFeedIds >= feedIdsEnd) break;
        }

        // Clear all cached slots to prevent stale data from leaking into subsequent calls
        // within the same transaction
        _clearTransientCache(payloadStart, payloadEnd);
    }

    /* ————————————————————————————————————————————————————————————————————————
                                INTERNAL CACHING LOGIC
    ————————————————————————————————————————————————————————————————————————— */
    /**
     * @dev Scan the signed payload and cache all packages into transient storage.
     * @dev Time complexity is O(N).
     * @dev Precondition: payloadStart < payloadEnd is guaranteed by _parseMetadata
     * (count >= 1, span >= FEED_PACKAGE_SIZE). Not re-checked here for gas optimization.
     * @param payloadStart The calldata offset where the first feed package begins
     * @param payloadEnd The calldata offset immediately after the last feed package
     */
    function _cacheFeedPackagesToTransientStorage(uint256 payloadStart, uint256 payloadEnd) internal {
        assembly ("memory-safe") {
            // Iterate through payload packages using constant stride
            // do-while: payloadStart < payloadEnd is guaranteed by _parseMetadata
            for {} 1 {} {
                let word := calldataload(payloadStart)
                tstore(and(word, FEED_ID_MASK), word)
                payloadStart := add(payloadStart, FEED_PACKAGE_SIZE)
                if iszero(lt(payloadStart, payloadEnd)) {
                    break
                }
            }
        }
    }

    /**
     * @dev Clear all feed packages previously cached by _cacheFeedPackagesToTransientStorage.
     * @dev Time complexity is O(N).
     * @dev Precondition: payloadStart < payloadEnd is guaranteed by _parseMetadata
     * (count >= 1, span >= FEED_PACKAGE_SIZE). Not re-checked here for gas optimization.
     * @dev Must be called after the lookup loop on every successful execution path to prevent
     * stale transient storage slots from leaking into subsequent calls within the same transaction.
     * @param payloadStart The calldata offset where the first feed package begins
     * @param payloadEnd The calldata offset immediately after the last feed package
     */
    function _clearTransientCache(uint256 payloadStart, uint256 payloadEnd) internal {
        assembly ("memory-safe") {
            // Iterate through the same range written by _cacheFeedPackagesToTransientStorage
            // do-while: payloadStart < payloadEnd is guaranteed by _parseMetadata
            for {} 1 {} {
                let word := calldataload(payloadStart)
                tstore(and(word, FEED_ID_MASK), 0)
                payloadStart := add(payloadStart, FEED_PACKAGE_SIZE)
                if iszero(lt(payloadStart, payloadEnd)) {
                    break
                }
            }
        }
    }

    /* ————————————————————————————————————————————————————————————————————————
                                  REFERENCE HOOKS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Hook to validate the aggregated timestamp; must revert internally if validation fails.
     * @param feedId the 4-byte identifier for the specific asset
     * @param parsedAggregateTimestamp the 48-bit timestamp extracted from the feed package
     */
    function _validateTimestamp(bytes4 feedId, uint256 parsedAggregateTimestamp) internal view virtual override {
        PullOracleReferenceHooks.validateTimestamp(feedId, parsedAggregateTimestamp);
    }

    /**
     * @dev Hook to define the maximum allowed packages per call.
     * @return the maximum number of packages allowed in a single update
     */
    function _getMaxPackageCount() internal view virtual override returns (uint256) {
        return PullOracleReferenceHooks.DEFAULT_MAX_PACKAGE_COUNT;
    }

    /**
     * @dev Hook to authorize the recovered signer address.
     * @param recoveredSigner the address recovered from the cryptographic signature
     * @return true if the recovered address is authorized to sign price data
     */
    function _isAuthorizedSigner(address recoveredSigner) internal view virtual override returns (bool) {
        return PullOracleReferenceHooks.isAuthorizedSigner(recoveredSigner);
    }
}
