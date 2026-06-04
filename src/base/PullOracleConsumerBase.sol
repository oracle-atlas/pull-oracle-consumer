// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {IPullOracleBase} from "interfaces/IPullOracleBase.sol";
import {CustomErrorRevert} from "libraries/CustomErrorRevert.sol";
import {PullOracleCodec} from "libraries/PullOracleCodec.sol";
import {PullOracleSignature} from "libraries/PullOracleSignature.sol";
import {FEED_PACKAGE_SIZE, FEED_ID_MASK} from "constants/Constants.sol";

/**
 * @title PullOracleConsumerBase
 * @notice Abstract base for Atlas Pull Oracle consumers with per-feed timestamp validation
 * @dev Re-implemented search logic to support direct calls to internal validation hooks
 */
abstract contract PullOracleConsumerBase is IPullOracleBase {
    using PullOracleCodec for bytes32;
    using CustomErrorRevert for bytes4;

    // Pre-computed error selector for `error UnmatchedFeedID(bytes4)`
    bytes4 internal constant UNMATCHED_FEED_ID_SELECTOR = 0x3411493b;

    // Define standardized price decimals for internal calculations
    uint256 internal constant PRICE_DECIMAL = 18;

    /* ————————————————————————————————————————————————————————————————————————
                            INTERNAL API: DATA ACCESSORS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Retrieve a cryptographically verified feed value from trailing extra data
     * @dev Reverts if the feed ID is missing, signature is invalid, or timestamp fails validation
     * @param feedId The unique 4-byte identifier for the asset feed
     * @return price The latest verified price from the authorized signer
     * @return aggregatedTimestamp Off-chain aggregated timestamp
     */
    function _getVerifiedFeedData(
        bytes4 feedId
    ) internal view virtual returns (uint256 price, uint256 aggregatedTimestamp) {
        // Authenticate identity and unpack layout from trailing extra data
        (uint256 payloadStart, uint256 payloadEnd) = _authenticateAndUnpackExtraData();

        // Execute strict search and revert if the feed is missing
        return _getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched(feedId, payloadStart, payloadEnd);
    }

    /**
     * @notice Batch retrieve multiple cryptographically verified feed values
     * @dev Reverts if ANY requested feed ID is missing or if the integrity check fails.
     * @param feedIds An array of 4-byte feed identifiers. For maximum flexibility, an empty
     *        array is not rejected — it short-circuits before authentication and returns
     *        empty result arrays. Duplicate entries are permitted and no deduplication is
     *        performed; each element is resolved independently.
     * @return prices An array of verified prices in the requested order
     * @return aggregatedTimestamps Off-chain aggregated timestamps
     */
    function _getVerifiedFeedDataBatch(
        bytes4[] memory feedIds
    ) internal view virtual returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        if (feedIds.length == 0) return (prices, aggregatedTimestamps);

        // Authenticate identity and unpack layout from trailing extra data
        (uint256 payloadStart, uint256 payloadEnd) = _authenticateAndUnpackExtraData();

        // Process bulk request and enforce presence of all requested feeds
        return _getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched(feedIds, payloadStart, payloadEnd);
    }

    /**
     * @notice Attempt to retrieve a verified feed value, falling back to zero if unmatched
     * @dev Only reverts on invalid signatures or stale data; missing IDs return (0, 0)
     * @param feedId The unique 4-byte identifier for the asset feed
     * @return price The verified price or 0 if the feed is absent from extra data
     * @return aggregatedTimestamp Off-chain aggregated timestamp or 0
     */
    function _getVerifiedFeedDataLenient(
        bytes4 feedId
    ) internal view virtual returns (uint256 price, uint256 aggregatedTimestamp) {
        // Authenticate identity and unpack layout from trailing extra data
        (uint256 payloadStart, uint256 payloadEnd) = _authenticateAndUnpackExtraData();

        // Execute search with implicit zero-fallback for unmatched feeds
        return _getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched(feedId, payloadStart, payloadEnd);
    }

    /**
     * @notice Batch retrieve multiple verified feeds with zero-initialization for missing IDs
     * @dev Ensures the call does not revert solely due to missing feeds in the payload.
     * @param feedIds An array of 4-byte feed identifiers. For maximum flexibility, an empty
     *        array is not rejected — it short-circuits before authentication and returns
     *        empty result arrays. Duplicate entries are permitted and no deduplication is
     *        performed; each element is resolved independently.
     * @return prices Arrays containing verified prices or 0 for missing feeds
     * @return aggregatedTimestamps Off-chain aggregated timestamps or 0
     */
    function _getVerifiedFeedDataBatchLenient(
        bytes4[] memory feedIds
    ) internal view virtual returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        if (feedIds.length == 0) return (prices, aggregatedTimestamps);

        // Authenticate identity and unpack layout from trailing extra data
        (uint256 payloadStart, uint256 payloadEnd) = _authenticateAndUnpackExtraData();

        // Fill results with verified data or zeros according to payload availability
        return _getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched(feedIds, payloadStart, payloadEnd);
    }

    /* ————————————————————————————————————————————————————————————————————————
                                STRICT MODE (REVERT)
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Search extra data for a specific feed ID, decode its value, and validate its timestamp.
     * Revert if the feed ID is missing from the signed payload.
     * @dev Performance: O(N) using pre-validated pointers with aggregated timestamp validation
     * @dev Precondition: payloadStart < payloadEnd is guaranteed by _parseMetadata
     * (count >= 1, span >= FEED_PACKAGE_SIZE). Not re-checked here for gas optimization.
     * @param feedId The 4-byte feed ID to locate
     * @param payloadStart Byte offset where the first feed package begins in the calldata
     * @param payloadEnd Byte offset immediately after the last feed package in extra data
     * @return price Decoded price for the specific feed ID
     * @return aggregatedTimestamp Decoded timestamp for the specific feed ID
     * @custom:reverts UnmatchedFeedID If the feed ID is missing from the signed payload
     * @custom:reverts _validateTimestamp Reverts if the aggregatedTimestamp fails the implementation-specific validity or freshness criteria
     */
    function _getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched(
        bytes4 feedId,
        uint256 payloadStart,
        uint256 payloadEnd
    ) internal view virtual returns (uint256 price, uint256 aggregatedTimestamp) {
        bytes32 word;

        assembly ("memory-safe") {
            // do-while: payloadStart < payloadEnd is guaranteed by _parseMetadata
            for {} 1 {} {
                let temp := calldataload(payloadStart)

                // Match target ID against high 4 bytes using the mask
                if eq(feedId, and(temp, FEED_ID_MASK)) {
                    word := temp
                    break
                }

                payloadStart := add(payloadStart, FEED_PACKAGE_SIZE)
                if iszero(lt(payloadStart, payloadEnd)) {
                    break
                }
            }

            // Throw error if no matching feed ID is found in the payload
            if iszero(word) {
                mstore(0x00, UNMATCHED_FEED_ID_SELECTOR)
                mstore(0x04, feedId)
                revert(0x00, 0x24)
            }
        }

        (price, aggregatedTimestamp) = word._parseFeedPackage();

        // Execute timestamp validity check which may revert internally on invalid values
        _validateTimestamp(feedId, aggregatedTimestamp);
    }

    /**
     * @notice Retrieve multiple verified feed values with per-feed timestamp validation.
     * Revert if any requested feed ID is missing from the signed payload.
     * @dev Performance: O(M*N) with parallel pointer stepping to bypass all bounds checks
     * @dev Precondition: payloadStart < payloadEnd is guaranteed by _parseMetadata
     * (count >= 1, span >= FEED_PACKAGE_SIZE). Not re-checked here for gas optimization.
     * @param feedIds Array of 4-byte feed IDs to locate
     * @param payloadStart Byte offset where the first feed package begins in the calldata
     * @param payloadEnd Byte offset immediately after the last feed package in extra data
     * @return prices Array of decoded prices in the same order as feedIds
     * @return aggregatedTimestamps Array of decoded timestamps in the same order as feedIds
     * @custom:reverts UnmatchedFeedID If any requested feed ID is missing from the signed payload
     * @custom:reverts _validateTimestamp Reverts if any aggregatedTimestamp fails the implementation-specific validity or freshness criteria
     */
    function _getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched(
        bytes4[] memory feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) internal view virtual returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
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

        // Using for(;;) + tail break as a do-while idiom: the caller guarantees
        // feedIds.length > 0, so the first iteration is unconditional.
        for (;;) {
            bytes32 word;
            bytes4 targetFeedId;

            // Perform low-level search for the specific feed ID in the signed payload area
            assembly ("memory-safe") {
                targetFeedId := mload(ptrFeedIds)
                let ptrSearch := payloadStart
                // Iterate through payload packages using constant stride
                // do-while: payloadStart < payloadEnd is guaranteed by _parseMetadata
                for {} 1 {} {
                    let temp := calldataload(ptrSearch)

                    // Match high 4 bytes against target feed ID using mask (both are left-aligned)
                    if eq(targetFeedId, and(temp, FEED_ID_MASK)) {
                        word := temp
                        break
                    }

                    ptrSearch := add(ptrSearch, FEED_PACKAGE_SIZE)
                    if iszero(lt(ptrSearch, payloadEnd)) {
                        break
                    }
                }

                // Throw error if no matching feed ID is found for the current target in the loop
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
    }

    /* ————————————————————————————————————————————————————————————————————————
                                LENIENT MODE (ZERO)
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Search extra data for a specific feed ID, decode its value, and validate its timestamp.
     * Returns zero values if the feed ID is missing from the signed payload.
     * @dev Performance: O(N) using pre-validated pointers with aggregated timestamp validation
     * @dev Precondition: payloadStart < payloadEnd is guaranteed by _parseMetadata
     * (count >= 1, span >= FEED_PACKAGE_SIZE). Not re-checked here for gas optimization.
     * @param feedId The 4-byte feed ID to locate
     * @param payloadStart Byte offset where the first feed package begins in the calldata
     * @param payloadEnd Byte offset immediately after the last feed package in extra data
     * @return price Decoded price for the specific feed ID or 0 if unmatched
     * @return aggregatedTimestamp Decoded timestamp for the specific feed ID or 0 if unmatched
     * @custom:reverts _validateTimestamp Reverts if the aggregatedTimestamp fails the implementation-specific validity or freshness criteria
     */
    function _getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched(
        bytes4 feedId,
        uint256 payloadStart,
        uint256 payloadEnd
    ) internal view virtual returns (uint256 price, uint256 aggregatedTimestamp) {
        bytes32 word;

        assembly ("memory-safe") {
            // do-while: payloadStart < payloadEnd is guaranteed by _parseMetadata
            for {} 1 {} {
                let temp := calldataload(payloadStart)

                // Match target ID against high 4 bytes using the mask
                if eq(feedId, and(temp, FEED_ID_MASK)) {
                    word := temp
                    break
                }

                payloadStart := add(payloadStart, FEED_PACKAGE_SIZE)
                if iszero(lt(payloadStart, payloadEnd)) {
                    break
                }
            }
        }

        // Decode and validate only upon successful match
        // Rely on implicit stack initialization to return zeros if unmatched
        if (word != 0) {
            (price, aggregatedTimestamp) = word._parseFeedPackage();
            _validateTimestamp(feedId, aggregatedTimestamp);
        }
    }

    /**
     * @notice Retrieve multiple verified feed values with per-feed timestamp validation.
     * Fills indices with zeros if the corresponding feed ID is missing from the payload.
     * @dev Performance: O(M*N) with parallel pointer stepping and conditional validation
     * @dev Precondition: payloadStart < payloadEnd is guaranteed by _parseMetadata
     * (count >= 1, span >= FEED_PACKAGE_SIZE). Not re-checked here for gas optimization.
     * @param feedIds Array of 4-byte feed IDs to locate
     * @param payloadStart Byte offset where the first feed package begins in the calldata
     * @param payloadEnd Byte offset immediately after the last feed package in extra data
     * @return prices Array of decoded prices, with 0 at indices where IDs were not found
     * @return aggregatedTimestamps Array of decoded timestamps, with 0 at indices where IDs were not found
     * @custom:reverts _validateTimestamp Reverts if any aggregatedTimestamp fails the implementation-specific validity or freshness criteria
     */
    function _getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched(
        bytes4[] memory feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) internal view virtual returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
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

        // Using for(;;) + tail break as a do-while idiom: the caller guarantees
        // feedIds.length > 0, so the first iteration is unconditional.
        for (;;) {
            bytes32 word;
            bytes4 targetFeedId;
            // Declare local variables to be implicitly reset to 0 at the start of each iteration
            uint256 price;
            uint256 aggregatedTimestamp;

            // Perform low-level search for the current target ID in the loop
            assembly ("memory-safe") {
                targetFeedId := mload(ptrFeedIds)
                let ptrSearch := payloadStart
                // Iterate through payload packages using constant stride
                // do-while: payloadStart < payloadEnd is guaranteed by _parseMetadata
                for {} 1 {} {
                    let temp := calldataload(ptrSearch)

                    // Match high 4 bytes against target feed ID using mask (both are left-aligned)
                    if eq(targetFeedId, and(temp, FEED_ID_MASK)) {
                        word := temp
                        break
                    }

                    ptrSearch := add(ptrSearch, FEED_PACKAGE_SIZE)
                    if iszero(lt(ptrSearch, payloadEnd)) {
                        break
                    }
                }
            }

            // Decode and validate only upon successful match
            if (word != 0) {
                // Decode package and validate timestamp validity only for matched feeds
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
    }

    /**
     * @dev Internal hook to authenticate signer and unpack layout from extra data.
     * The returned pointers satisfy the invariant payloadStart < payloadEnd, guaranteed
     * by _parseMetadata (count >= 1, span >= FEED_PACKAGE_SIZE).
     * @return payloadStart Byte offset where the first feed package begins in the calldata
     * @return payloadEnd Byte offset immediately after the last feed package
     */
    function _authenticateAndUnpackExtraData()
        internal
        view
        virtual
        returns (uint256 payloadStart, uint256 payloadEnd)
    {
        // Unpack metadata from the tail of extra data
        (payloadStart, payloadEnd) = PullOracleCodec._parseMetadata(_getMaxPackageCount());

        // Recover signer address from the extra data payload using calldata offsets
        address signer = PullOracleSignature._recoverSigner(payloadStart, payloadEnd);

        // Revert upon unauthorized signer
        if (!_isAuthorizedSigner(signer)) UnauthorizedSigner.selector.revertWith(signer);
    }

    /**
     * @dev Hook to validate the aggregated timestamp; must revert internally if validation fails
     * @param feedId The 4-byte identifier for the specific asset
     * @param parsedAggregateTimestamp The 48-bit timestamp extracted from the feed package
     */
    function _validateTimestamp(bytes4 feedId, uint256 parsedAggregateTimestamp) internal view virtual;

    /**
     * @dev Hook to define the maximum allowed packages per call
     */
    function _getMaxPackageCount() internal view virtual returns (uint256);

    /**
     * @dev Hook to authorize the recovered signer address
     */
    function _isAuthorizedSigner(address recoveredSigner) internal view virtual returns (bool);
}
