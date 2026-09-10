// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24; // Minimum 0.8.24 required for Cancun opcodes

import {PullOracleConsumerTransient} from "src-advanced/PullOracleConsumerTransient.sol";
import {FEED_PACKAGE_SIZE} from "src/constants/Constants.sol";

/**
 * Tron-side test harness for PullOracleConsumerTransient.
 *
 * Deliberately separate from PullOracleConsumerTransientMock (its name is 31
 * bytes, fine for TVM, but the shared file must stay untouched per repo
 * convention). Surface mirrors the shared mock minus cacheAndClearForTest,
 * which the merged probes subsume; the three *ProbeForTest functions are
 * TVM-only additions.
 *
 * WHY THE PROBES EXIST — transient lifetime on TRE: transient storage lives
 * for one transaction, and every TRE constant call IS one transaction. The
 * Foundry suite proves cross-CALL persistence (cache in call 1, read in
 * call 2 of the same test tx) — that cannot be replayed as two constant
 * calls. Each probe therefore folds the second call frame into one entry
 * point: the mock caches in its frame, then opens a nested sub-call frame
 * that reads the slots, preserving the cross-frame property under test.
 *
 * The foreign-poison probe inverts Foundry's caller-side TSTORE into a
 * second-contract write (an EOA cannot TSTORE): the writer contract poisons
 * its OWN slot space under the same keys, after which the mock reads its own
 * slots. EIP-1153 slot isolation is per-address and symmetric, so the
 * writer-as-callee shape covers the same guarantee.
 */
contract ConsumerTransientTvmMock is PullOracleConsumerTransient {
    // Payload for the foreign TSTORE in the isolation probe (value irrelevant).
    bytes32 constant POISON_WORD = 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef;

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
     * Atomic: cache packages and immediately read them back (same frame).
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
     * Cache, read back before and after clearing — zeroing-behaviour proof.
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
     * TVM-only probe for the Foundry cross-call leak test (cache in call 1,
     * read in call 2): cache without clearing, then read the slots from a
     * NESTED sub-call frame — the stale words must survive the frame boundary.
     */
    function cacheLeakProbeForTest(
        bytes4[] calldata checkIds,
        uint256 payloadStart,
        uint256 count
    ) external returns (bytes32[] memory) {
        uint256 payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
        _cacheFeedPackagesToTransientStorage(payloadStart, payloadEnd);

        (bool ok, bytes memory ret) = address(this).call(
            abi.encodeWithSelector(this.readTransientSlotsForTest.selector, checkIds)
        );
        require(ok, "cacheLeakProbe: sub-frame read failed");
        return abi.decode(ret, (bytes32[]));
    }

    /**
     * TVM-only probe: cache + clear, then read from a nested sub-call frame —
     * a complete invocation must leave no residue observable from a later frame.
     */
    function cacheClearProbeForTest(
        bytes4[] calldata checkIds,
        uint256 payloadStart,
        uint256 count
    ) external returns (bytes32[] memory) {
        uint256 payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
        _cacheFeedPackagesToTransientStorage(payloadStart, payloadEnd);
        _clearTransientCache(payloadStart, payloadEnd);

        (bool ok, bytes memory ret) = address(this).call(
            abi.encodeWithSelector(this.readTransientSlotsForTest.selector, checkIds)
        );
        require(ok, "cacheClearProbe: sub-frame read failed");
        return abi.decode(ret, (bytes32[]));
    }

    /**
     * TVM-only probe for the EIP-1153 per-address isolation test: cache, let a
     * SECOND contract TSTORE the same keys (into its own slot space), then read
     * our own slots — they must be untouched by the foreign write.
     */
    function cacheForeignPoisonProbeForTest(
        bytes4[] calldata checkIds,
        uint256 payloadStart,
        uint256 count,
        address poisoner
    ) external returns (bytes32[] memory) {
        uint256 payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
        _cacheFeedPackagesToTransientStorage(payloadStart, payloadEnd);

        TransientSlotWriter(poisoner).writeBatch(checkIds, POISON_WORD);

        return _tloadSlots(checkIds);
    }

    /**
     * Read transient slots for a set of IDs without performing any caching
     * (sub-frame reader for the probes above; also callable directly).
     */
    function readTransientSlotsForTest(bytes4[] calldata checkIds) external view returns (bytes32[] memory) {
        return _tloadSlots(checkIds);
    }

    /**
     * Batch TLOAD a set of feed IDs and return the raw words.
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
     * Write arbitrary foreign data to transient slots keyed by feed IDs.
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

/**
 * Foreign TSTORE writer for the per-address isolation probe: writes into its
 * OWN transient slot space under the same keys the mock uses, proving slot
 * keys are scoped to the writing contract (EIP-1153).
 */
contract TransientSlotWriter {
    function writeBatch(bytes4[] calldata keys, bytes32 word) external {
        for (uint256 i = 0; i < keys.length; ) {
            bytes4 key = keys[i];
            assembly {
                tstore(key, word)
            }
            unchecked {
                ++i;
            }
        }
    }
}
