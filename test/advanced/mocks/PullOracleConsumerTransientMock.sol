// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24; // Minimum 0.8.24 required for Cancun opcodes

import {PullOracleConsumerTransient} from "src-advanced/PullOracleConsumerTransient.sol";
import {FEED_PACKAGE_SIZE} from "src/constants/Constants.sol";

/**
 * Test wrapper to expose internal transient storage logic for audit and verification
 */
contract PullOracleConsumerTransientMock is PullOracleConsumerTransient {
    /*
     * Implementation of authorization check using hardcoded test signer addresses
     * Test signers: 0x532FAFF264Be605F7cca78Db5662fdCBE689FC5d (primary)
     *               0xf41C5b73ac6EfCFA6c6E71eF64aE3F0815f0CF49 (secondary)
     */
    function _isAuthorizedSigner(address recoveredSigner) internal pure override returns (bool) {
        return (recoveredSigner == 0x532FAFF264Be605F7cca78Db5662fdCBE689FC5d ||
            recoveredSigner == 0xf41C5b73ac6EfCFA6c6E71eF64aE3F0815f0CF49);
    }

    function getVerifiedFeedDataBatchTransient(
        bytes4[] calldata feedIds
    ) external returns (uint256[] memory, uint256[] memory) {
        return _getVerifiedFeedDataBatchTransient(feedIds);
    }

    function getVerifiedFeedDataBatchLenientTransient(
        bytes4[] calldata feedIds
    ) external returns (uint256[] memory, uint256[] memory) {
        return _getVerifiedFeedDataBatchLenientTransient(feedIds);
    }

    function getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(
        bytes4[] calldata feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) external returns (uint256[] memory, uint256[] memory) {
        return
            _getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(
                feedIds,
                payloadStart,
                payloadEnd
            );
    }

    function getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(
        bytes4[] calldata feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) external returns (uint256[] memory, uint256[] memory) {
        return _getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(feedIds, payloadStart, payloadEnd);
    }

    /**
     * Atomic function to cache packages and immediately read them back
     */
    function cacheAndReadBackForTest(
        bytes4[] calldata checkIds,
        uint256 payloadStart,
        uint256 count
    ) external returns (bytes32[] memory) {
        uint256 payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
        _cacheFeedPackagesToTransientStorage(payloadStart, payloadEnd);
        return _tloadSlots(checkIds);
    }

    /**
     * Cache packages, read them back before and after clearing, to verify zeroing behaviour
     */
    function cacheReadClearReadForTest(
        bytes4[] calldata checkIds,
        uint256 payloadStart,
        uint256 count
    ) external returns (bytes32[] memory beforeClear, bytes32[] memory afterClear) {
        uint256 payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
        _cacheFeedPackagesToTransientStorage(payloadStart, payloadEnd);

        beforeClear = _tloadSlots(checkIds);

        _clearTransientCache(payloadStart, payloadEnd);

        afterClear = _tloadSlots(checkIds);
    }

    /**
     * Cache packages then immediately clear — used to simulate a complete invocation for cross-call tests
     */
    function cacheAndClearForTest(uint256 payloadStart, uint256 count) external {
        uint256 payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
        _cacheFeedPackagesToTransientStorage(payloadStart, payloadEnd);
        _clearTransientCache(payloadStart, payloadEnd);
    }

    /**
     * Read transient slots for a set of IDs without performing any caching — used in cross-call tests
     */
    function readTransientSlotsForTest(bytes4[] calldata checkIds) external view returns (bytes32[] memory) {
        return _tloadSlots(checkIds);
    }

    /**
     * Batch TLOAD a set of feed IDs and return the raw words
     */
    function _tloadSlots(bytes4[] calldata ids) private view returns (bytes32[] memory results) {
        results = new bytes32[](ids.length);
        for (uint256 i = 0; i < ids.length; ) {
            bytes4 id = ids[i];
            bytes32 val;
            assembly {
                val := tload(id)
            }
            results[i] = val;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * Write foreign transient data then invoke strict batch lookup.
     * Simulates a scenario where prior logic in the same transaction polluted transient slots.
     */
    function strictBatchWithForeignTransientData(
        bytes4[] calldata poisonedIds,
        bytes32 foreignWord,
        bytes4[] calldata feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) external returns (uint256[] memory, uint256[] memory) {
        _poisonTransientSlots(poisonedIds, foreignWord);
        return
            _getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(
                feedIds,
                payloadStart,
                payloadEnd
            );
    }

    /**
     * Write foreign transient data then invoke lenient batch lookup.
     * Simulates a scenario where prior logic in the same transaction polluted transient slots.
     */
    function lenientBatchWithForeignTransientData(
        bytes4[] calldata poisonedIds,
        bytes32 foreignWord,
        bytes4[] calldata feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) external returns (uint256[] memory, uint256[] memory) {
        _poisonTransientSlots(poisonedIds, foreignWord);
        return _getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(feedIds, payloadStart, payloadEnd);
    }

    /**
     * Write arbitrary foreign data to transient slots keyed by feed IDs
     */
    function _poisonTransientSlots(bytes4[] calldata ids, bytes32 word) private {
        for (uint256 i = 0; i < ids.length; ) {
            bytes4 key = ids[i];
            assembly {
                tstore(key, word)
            }
            unchecked {
                ++i;
            }
        }
    }
}
