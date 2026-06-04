// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPullOracleBase} from "src/interfaces/IPullOracleBase.sol";
import {IPullOracleReferenceHooks} from "src/interfaces/IPullOracleReferenceHooks.sol";
import {BaseTest} from "test/utils/BaseTest.t.sol";
import {PullOracleConsumerTransientMock} from "test/advanced/mocks/PullOracleConsumerTransientMock.sol";
import {LowLevelReverter} from "test/utils/LowLevelReverter.sol";

/*
 * Verify the transient storage caching mechanism and its physical memory alignment
 */
contract PullOracleConsumerTransientTest is BaseTest {
    using LowLevelReverter for address;

    PullOracleConsumerTransientMock internal mock = new PullOracleConsumerTransientMock();

    bytes4 internal constant TARGET_ID = 0x11223344;
    uint256 internal constant TARGET_PRICE = 50000e18;

    // Define 20-byte mask
    bytes32 internal constant HIGH_20_BYTES_MASK = 0xffffffffffffffffffffffffffffffffffffffff000000000000000000000000;

    function setUp() public virtual {
        vm.warp(1 days);
    }

    /*
     * Verify the transient caching engine with left-aligned word comparison
     */
    function test_cacheFeedPackagesToTransientStorage_PhysicalAlignment() public {
        uint256 count = 5;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("transient", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp - i;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + count(32) + array_len(32) + 5*ids(160)
        uint256 payloadStartOffset = 4 + 32 + 32 + 32 + 32 + (count * 32);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.cacheAndReadBackForTest.selector,
            ids,
            payloadStartOffset,
            count
        );

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        bytes32[] memory cachedWords = abi.decode(returnData, (bytes32[]));

        for (uint256 i = 0; i < count; ) {
            bytes32 expected = _encodeLeftAlignedPackage(ids[i], prices[i], timestamps[i]);
            assertEq(cachedWords[i] & HIGH_20_BYTES_MASK, expected, "High 160-bit mismatch at package index");
            unchecked {
                ++i;
            }
        }
    }

    /**
     * Verify that duplicate IDs in payload result in LIFO (Last-In-First-Out) overwrite in TSTORE
     * Physical later package in calldata must prevail in transient storage
     */
    function test_cacheFeedPackagesToTransientStorage_LIFO_Overwrite() public {
        uint256 count = 3;
        bytes4 otherId = bytes4(0x99999999);

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        // Package 0: Target ID (Stale)
        ids[0] = TARGET_ID;
        prices[0] = TARGET_PRICE - 2;
        timestamps[0] = block.timestamp;

        // Package 1: Other ID (Independent)
        ids[1] = otherId;
        prices[1] = TARGET_PRICE - 1;
        timestamps[1] = block.timestamp;

        // Package 2: Target ID (Fresh - Should Overwrite Package 0)
        ids[2] = TARGET_ID;
        prices[2] = TARGET_PRICE;
        timestamps[2] = block.timestamp + 1;

        bytes4[] memory checkIds = new bytes4[](2);
        checkIds[0] = TARGET_ID;
        checkIds[1] = otherId;

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);
        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + count(32) + array_len(32) + 2*ids(64)
        uint256 payloadOffset = 4 + 32 + 32 + 32 + 32 + (checkIds.length * 32);

        bytes memory businessCall = abi.encodeWithSelector(
            mock.cacheAndReadBackForTest.selector,
            checkIds,
            payloadOffset,
            count
        );

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        bytes32[] memory results = abi.decode(returnData, (bytes32[]));

        // Verify Target ID (Must match the LAST package)
        bytes32 freshTarget = _encodeLeftAlignedPackage(ids[2], prices[2], timestamps[2]);
        assertEq(
            results[0] & HIGH_20_BYTES_MASK,
            freshTarget,
            "Target ID slot was not overwritten by the last package"
        );

        // Verify Other ID (Must remain intact and correct)
        bytes32 expectedOther = _encodeLeftAlignedPackage(ids[1], prices[1], timestamps[1]);
        assertEq(results[1] & HIGH_20_BYTES_MASK, expectedOther, "Other ID slot was corrupted during target overwrite");
    }

    /* ————————————————————————————————————————————————————————————————————————
                            TRANSIENT CACHE: CLEAR VERIFICATION
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify that _clearTransientCache zeros every slot that was written by _cacheFeedPackagesToTransientStorage.
     * Reads are taken before and after the clear within the same call frame to confirm the transition.
     */
    function test_clearTransientCache_ZerosAllCachedSlots() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("clear_test", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + count(32) + array_len(32) + 3*ids(96)
        uint256 payloadStartOffset = 4 + 32 + 32 + 32 + 32 + (count * 32);

        bytes memory businessCall = abi.encodeWithSelector(
            mock.cacheReadClearReadForTest.selector,
            ids,
            payloadStartOffset,
            count
        );

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (bytes32[] memory beforeClear, bytes32[] memory afterClear) = abi.decode(returnData, (bytes32[], bytes32[]));

        for (uint256 i = 0; i < count; ) {
            // Before clear: high 160 bits must match the cached package
            bytes32 expected = _encodeLeftAlignedPackage(ids[i], prices[i], timestamps[i]);
            assertEq(beforeClear[i] & HIGH_20_BYTES_MASK, expected, "Pre-clear: slot must contain cached package data");
            // After clear: entire slot must be zero
            assertEq(afterClear[i], bytes32(0), "Post-clear: slot must be fully zeroed");
            unchecked {
                ++i;
            }
        }
    }

    /*
     * Demonstrate that without an explicit clear, cached slots leak into a subsequent call
     * within the same transaction. This is the vulnerability that _clearTransientCache guards against.
     */
    function test_clearTransientCache_WithoutClear_SlotsLeakAcrossCalls() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("leak_test", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + count(32) + array_len(32) + 3*ids(96)
        uint256 payloadStartOffset = 4 + 32 + 32 + 32 + 32 + (count * 32);

        // First call: cache WITHOUT clearing — simulates the pre-fix behaviour
        bytes memory call1 = abi.encodeWithSelector(
            mock.cacheAndReadBackForTest.selector,
            ids,
            payloadStartOffset,
            count
        );

        (bool success1, ) = address(mock).call(_attachExtraData(call1, extraData));
        assertTrue(success1);

        // Second call (same tx): read slots without caching — stale data must still be visible
        bytes memory call2 = abi.encodeWithSelector(mock.readTransientSlotsForTest.selector, ids);

        (bool success2, bytes memory returnData2) = address(mock).staticcall(call2);
        assertTrue(success2);

        bytes32[] memory results = abi.decode(returnData2, (bytes32[]));

        for (uint256 i = 0; i < count; ) {
            bytes32 expected = _encodeLeftAlignedPackage(ids[i], prices[i], timestamps[i]);
            assertEq(
                results[i] & HIGH_20_BYTES_MASK,
                expected,
                "Stale slot must still be readable across calls when no clear is performed"
            );
            unchecked {
                ++i;
            }
        }
    }

    /*
     * Verify that after a complete invocation (cache + clear), a subsequent call within the same
     * transaction cannot observe any residual data from the previous call's transient slots.
     */
    function test_clearTransientCache_PreventsCrossCallContamination() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("contamination_test", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        // Layout: Selector(4) + payloadStart(32) + count(32) — no array parameter
        uint256 payloadStartOffset = 4 + 32 + 32;

        // First call: cache + clear (simulates a complete, properly-implemented invocation)
        bytes memory call1 = abi.encodeWithSelector(mock.cacheAndClearForTest.selector, payloadStartOffset, count);

        (bool success1, ) = address(mock).call(_attachExtraData(call1, extraData));
        assertTrue(success1);

        // Second call (same tx): read slots without caching — must find all slots zeroed
        bytes memory call2 = abi.encodeWithSelector(mock.readTransientSlotsForTest.selector, ids);

        (bool success2, bytes memory returnData2) = address(mock).staticcall(call2);
        assertTrue(success2);

        bytes32[] memory results = abi.decode(returnData2, (bytes32[]));

        for (uint256 i = 0; i < count; ) {
            assertEq(results[i], bytes32(0), "Slot must be zero after clear: no cross-call contamination");
            unchecked {
                ++i;
            }
        }
    }

    /*
     * Verify that transient storage is isolated per contract address (EIP-1153).
     * A TSTORE issued by the caller (this test contract) must not affect the callee's (mock) transient slots.
     */
    function test_clearTransientCache_CallerTstoreDoesNotAffectCalleeSlots() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("isolation_test", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + count(32) + array_len(32) + 3*ids(96)
        uint256 payloadStartOffset = 4 + 32 + 32 + 32 + 32 + (count * 32);

        // Step 1: Cache feed packages into mock's transient storage (without clear)
        bytes memory call1 = abi.encodeWithSelector(
            mock.cacheAndReadBackForTest.selector,
            ids,
            payloadStartOffset,
            count
        );

        (bool success1, bytes memory returnData1) = address(mock).call(_attachExtraData(call1, extraData));
        assertTrue(success1);

        // Capture the original cached words for later comparison
        bytes32[] memory originalWords = abi.decode(returnData1, (bytes32[]));

        // Step 2: From THIS contract (the caller), TSTORE into the same slot keys used by mock
        // EIP-1153 guarantees this writes to the test contract's transient storage, not mock's
        for (uint256 i = 0; i < count; ) {
            bytes4 id = ids[i];
            assembly {
                tstore(id, 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef)
            }
            unchecked {
                ++i;
            }
        }

        // Step 3: Read back from mock's transient storage — must be unchanged
        bytes memory call2 = abi.encodeWithSelector(mock.readTransientSlotsForTest.selector, ids);

        (bool success2, bytes memory returnData2) = address(mock).staticcall(call2);
        assertTrue(success2);

        bytes32[] memory results = abi.decode(returnData2, (bytes32[]));

        for (uint256 i = 0; i < count; ) {
            assertEq(results[i], originalWords[i], "Mock's transient slot must be unaffected by caller's TSTORE");
            unchecked {
                ++i;
            }
        }
    }

    /* ————————————————————————————————————————————————————————————————————————
                            STRICT MODE (TRANSIENT): BATCH SEARCH 
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate successful batch retrieval and memory allocation for multiple requested IDs
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient_Success() public {
        uint256 payloadCount = 5;
        uint256 requestedCount = 3;
        bytes4[] memory requestedIds = new bytes4[](requestedCount);
        requestedIds[0] = 0x11111111; // Located at payload index 0
        requestedIds[1] = 0x22222222; // Located at payload index 2
        requestedIds[2] = 0x33333333; // Located at payload index 4

        uint256[] memory expectedPrices = new uint256[](requestedCount);
        expectedPrices[0] = 100e18;
        expectedPrices[1] = 200e18;
        expectedPrices[2] = 300e18;

        uint256 currentTs = block.timestamp;

        // Initialize payload arrays for _buildUnsignedExtraData
        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        // Populate payload with targets and unique dummy data
        for (uint256 i = 0; i < payloadCount; ) {
            if (i == 0) {
                payloadIds[i] = requestedIds[0];
                payloadPrices[i] = expectedPrices[0];
            } else if (i == 2) {
                payloadIds[i] = requestedIds[1];
                payloadPrices[i] = expectedPrices[1];
            } else if (i == 4) {
                payloadIds[i] = requestedIds[2];
                payloadPrices[i] = expectedPrices[2];
            } else {
                payloadIds[i] = bytes4(keccak256(abi.encode("dummy", i)));
                payloadPrices[i] = 50e18;
            }
            // All packages use unique timestamps staggered by index
            payloadTimestamps[i] = currentTs - i;
            unchecked {
                ++i;
            }
        }

        // Calculate physical offset for batch function
        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + payloadEnd(32) + array_len(32) + 3*ids(96)
        uint256 payloadStart = 4 + 32 + 32 + 32 + 32 + (requestedIds.length * 32);

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient.selector,
            requestedIds,
            payloadStart,
            payloadStart + payloadCount * 20
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory prices, uint256[] memory ts) = abi.decode(returnData, (uint256[], uint256[]));
        // Assert batch integrity and order preservation
        assertEq(prices.length, requestedCount);
        assertEq(ts.length, requestedCount);

        for (uint256 j = 0; j < requestedCount; ) {
            assertEq(prices[j], expectedPrices[j]);
            assertEq(ts[j], currentTs - (j * 2)); // Corresponds to indices 0, 2, 4 in payload
            unchecked {
                ++j;
            }
        }
    }

    /*
     * Verify revert with UnmatchedFeedID when at least one requested ID is missing from the payload
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient_Revert_PartialUnmatchedID()
        public
    {
        uint256 payloadCount = 5;
        uint256 requestedCount = 3;

        // ID at index 1 is intentionally missing from the payload
        bytes4[] memory requestedIds = new bytes4[](requestedCount);
        requestedIds[0] = 0x11111111; // Present at payload index 0
        requestedIds[1] = 0xdeadbeef; // Missing target
        requestedIds[2] = 0x33333333; // Present at payload index 4

        // Initialize parallel arrays for _buildUnsignedExtraData
        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        // Populate payload where requestedIds[1] is absent and replaced by dummy data
        for (uint256 i = 0; i < payloadCount; ) {
            if (i == 0) {
                payloadIds[i] = requestedIds[0];
            } else if (i == 4) {
                payloadIds[i] = requestedIds[2];
            } else {
                // Ensure no dummy ID matches the missing target
                payloadIds[i] = bytes4(keccak256(abi.encode("dummy", i)));
            }
            payloadPrices[i] = 100e18;
            payloadTimestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + payloadEnd(32) + array_len(32) + 3*ids(96)
        uint256 payloadStart = 4 + 32 + 32 + 32 + 32 + (requestedCount * 32);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, requestedIds[1]));

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify revert when a specific ID within a batch fails freshness validation
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient_Revert_PartialExpired()
        public
    {
        uint256 payloadCount = 5;
        uint256 requestedCount = 3;
        uint256 currentTimestamp = block.timestamp;

        // Define an expired timestamp that exceeds the protocol default 180s limit
        uint256 expiredTimestamp = currentTimestamp - 181;

        bytes4[] memory requestedIds = new bytes4[](requestedCount);
        requestedIds[0] = 0x11111111; // Fresh
        requestedIds[1] = 0x22222222; // Fresh
        requestedIds[2] = 0x33333333; // Expired

        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        // Populate payload with targets staggered across the 5 packages
        for (uint256 i = 0; i < payloadCount; ) {
            if (i == 0) {
                payloadIds[i] = requestedIds[0];
                payloadTimestamps[i] = currentTimestamp;
            } else if (i == 2) {
                payloadIds[i] = requestedIds[1];
                payloadTimestamps[i] = currentTimestamp;
            } else if (i == 4) {
                payloadIds[i] = requestedIds[2];
                payloadTimestamps[i] = expiredTimestamp; // Inject expired data at the last payload slot
            } else {
                payloadIds[i] = bytes4(keccak256(abi.encode("dummy", i)));
                payloadTimestamps[i] = currentTimestamp;
            }
            payloadPrices[i] = 100e18;
            unchecked {
                ++i;
            }
        }

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + payloadEnd(32) + array_len(32) + 3*ids(96)
        uint256 payloadStart = 4 + 32 + 32 + 32 + 32 + (requestedCount * 32);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                requestedIds[2],
                expiredTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify revert when a specific ID within a batch drifts too far into the future
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient_Revert_PartialFutureDrift()
        public
    {
        uint256 payloadCount = 5;
        uint256 requestedCount = 3;
        uint256 currentTimestamp = block.timestamp;

        // Define a future timestamp that exceeds the default 60s drift limit
        uint256 futureTimestamp = currentTimestamp + 61;

        bytes4[] memory requestedIds = new bytes4[](requestedCount);
        requestedIds[0] = 0x11111111; // Fresh
        requestedIds[1] = 0x22222222; // Future Drift target
        requestedIds[2] = 0x33333333; // Fresh

        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        // Populate payload where requestedIds[1] is matched at index 2 with future data
        for (uint256 i = 0; i < payloadCount; ) {
            if (i == 0) {
                payloadIds[i] = requestedIds[0];
                payloadTimestamps[i] = currentTimestamp;
            } else if (i == 2) {
                payloadIds[i] = requestedIds[1];
                payloadTimestamps[i] = futureTimestamp; // Inject drifting timestamp
            } else if (i == 4) {
                payloadIds[i] = requestedIds[2];
                payloadTimestamps[i] = currentTimestamp;
            } else {
                payloadIds[i] = bytes4(keccak256(abi.encode("dummy", i)));
                payloadTimestamps[i] = currentTimestamp;
            }
            payloadPrices[i] = 100e18;
            unchecked {
                ++i;
            }
        }

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + payloadEnd(32) + array_len(32) + 3*ids(96)
        uint256 payloadStart = 4 + 32 + 32 + 32 + 32 + (requestedCount * 32);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                requestedIds[1],
                futureTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            LENIENT MODE (TRANSIENT): BATCH SEARCH
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate batch retrieval in lenient mode where missing IDs result in zero values instead of reverts
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient_Success_PartialMissing() public {
        uint256 payloadCount = 5;
        uint256 requestedCount = 3;

        bytes4[] memory requestedIds = new bytes4[](requestedCount);
        requestedIds[0] = 0x11111111; // Present
        requestedIds[1] = 0xdeadbeef; // Missing
        requestedIds[2] = 0x33333333; // Present

        uint256 currentTs = block.timestamp;

        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        for (uint256 i = 0; i < payloadCount; ) {
            if (i == 0) {
                payloadIds[i] = requestedIds[0];
                payloadPrices[i] = 100e18;
            } else if (i == 4) {
                payloadIds[i] = requestedIds[2];
                payloadPrices[i] = 300e18;
            } else {
                payloadIds[i] = bytes4(keccak256(abi.encode("dummy", i)));
                payloadPrices[i] = 50e18;
            }
            payloadTimestamps[i] = currentTs;
            unchecked {
                ++i;
            }
        }

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + payloadEnd(32) + array_len(32) + 3*ids(96)
        uint256 payloadStart = 4 + 32 + 32 + 32 + 32 + (requestedCount * 32);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory prices, uint256[] memory ts) = abi.decode(returnData, (uint256[], uint256[]));

        // Assert array lengths
        assertEq(prices.length, requestedCount);
        assertEq(ts.length, requestedCount);

        // Verify index 0: Found
        assertEq(prices[0], 100e18);
        assertEq(ts[0], currentTs);

        // Verify index 1: Missing -> Zero
        assertEq(prices[1], 0);
        assertEq(ts[1], 0);

        // Verify index 2: Found
        assertEq(prices[2], 300e18);
        assertEq(ts[2], currentTs);
    }

    /*
     * Ensure the function returns all zero values when none of the requested IDs exist in the payload
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient_Success_AllMissing() public {
        uint256 payloadCount = 5;
        uint256 requestedCount = 3;

        bytes4[] memory requestedIds = new bytes4[](requestedCount);
        requestedIds[0] = 0xaaaaaaaa;
        requestedIds[1] = 0xbbbbbbbb;
        requestedIds[2] = 0xcccccccc;

        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        for (uint256 i = 0; i < payloadCount; ) {
            payloadIds[i] = bytes4(keccak256(abi.encode("other", i)));
            payloadPrices[i] = 100e18;
            payloadTimestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + payloadEnd(32) + array_len(32) + 3*ids(96)
        uint256 payloadStart = 4 + 32 + 32 + 32 + 32 + (requestedCount * 32);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory prices, uint256[] memory ts) = abi.decode(returnData, (uint256[], uint256[]));

        assertEq(prices.length, requestedCount);
        assertEq(ts.length, requestedCount);

        // Verify every element is zero as no matches were found
        for (uint256 j = 0; j < requestedCount; ) {
            assertEq(prices[j], 0);
            assertEq(ts[j], 0);
            unchecked {
                ++j;
            }
        }
    }

    /*
     * Ensure lenient batch search still reverts if a matched ID fails freshness validation
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient_Revert_PartialExpired() public {
        uint256 payloadCount = 5;
        uint256 requestedCount = 3;
        uint256 currentTimestamp = block.timestamp;

        // Define an expired timestamp exceeding the 180s limit
        uint256 expiredTimestamp = currentTimestamp - 181;

        bytes4[] memory requestedIds = new bytes4[](requestedCount);
        requestedIds[0] = 0x11111111; // Fresh
        requestedIds[1] = 0xdeadbeef; // Missing
        requestedIds[2] = 0x33333333; // Matched but Expired

        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        // Populate payload where requestedIds[2] is matched at index 4 with expired data
        for (uint256 i = 0; i < payloadCount; ) {
            if (i == 0) {
                payloadIds[i] = requestedIds[0];
                payloadTimestamps[i] = currentTimestamp;
            } else if (i == 4) {
                payloadIds[i] = requestedIds[2];
                payloadTimestamps[i] = expiredTimestamp;
            } else {
                payloadIds[i] = bytes4(keccak256(abi.encode("dummy", i)));
                payloadTimestamps[i] = currentTimestamp;
            }
            payloadPrices[i] = 100e18;
            unchecked {
                ++i;
            }
        }

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + payloadEnd(32) + array_len(32) + 3*ids(96)
        uint256 payloadStart = 4 + 32 + 32 + 32 + 32 + (requestedCount * 32);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                requestedIds[2],
                expiredTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Ensure lenient batch search still reverts if a matched ID drifts into the future
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient_Revert_PartialFutureDrift()
        public
    {
        uint256 payloadCount = 5;
        uint256 requestedCount = 3;
        uint256 currentTimestamp = block.timestamp;

        // Define a future timestamp exceeding the 60s drift limit
        uint256 futureTimestamp = currentTimestamp + 61;

        bytes4[] memory requestedIds = new bytes4[](requestedCount);
        requestedIds[0] = 0x11111111; // Matched but Future Drift
        requestedIds[1] = 0x22222222; // Fresh
        requestedIds[2] = 0x33333333; // Fresh

        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        // Populate payload with drifting data at the first hit to test early-exit revert
        for (uint256 i = 0; i < payloadCount; ) {
            if (i == 0) {
                payloadIds[i] = requestedIds[0];
                payloadTimestamps[i] = futureTimestamp;
            } else if (i == 2) {
                payloadIds[i] = requestedIds[1];
                payloadTimestamps[i] = currentTimestamp;
            } else if (i == 4) {
                payloadIds[i] = requestedIds[2];
                payloadTimestamps[i] = currentTimestamp;
            } else {
                payloadIds[i] = bytes4(keccak256(abi.encode("dummy", i)));
                payloadTimestamps[i] = currentTimestamp;
            }
            payloadPrices[i] = 100e18;
            unchecked {
                ++i;
            }
        }

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + payloadEnd(32) + array_len(32) + 3*ids(96)
        uint256 payloadStart = 4 + 32 + 32 + 32 + 32 + (requestedCount * 32);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                requestedIds[0],
                futureTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            INTERNAL API (TRANSIENT): STRICT BATCH
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate integrated batch retrieval for multiple identifiers within a verified payload
     */
    function test_getVerifiedFeedDataBatchTransient_Success() public {
        uint256 count = 3;
        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp - i;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[2];
        requestedIds[1] = ids[0];

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchTransient.selector,
            requestedIds
        );
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));

        assertEq(rPrices[0], prices[2]);
        assertEq(rPrices[1], prices[0]);
        assertEq(rTs[0], timestamps[2]);
        assertEq(rTs[1], timestamps[0]);
    }

    /*
     * Verify strict batch retrieval handles duplicate requested identifiers by resolving each independently
     */
    function test_getVerifiedFeedDataBatchTransient_Success_DuplicateRequestedIDs() public {
        uint256 count = 3;

        uint256 currentTs = block.timestamp;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = currentTs - i;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](3);
        requestedIds[0] = ids[1];
        requestedIds[1] = ids[1]; // Duplicate
        requestedIds[2] = ids[0];

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchTransient.selector,
            requestedIds
        );
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));

        assertEq(rPrices[0], prices[1]);
        assertEq(rPrices[1], prices[1]);
        assertEq(rPrices[2], prices[0]);
        assertEq(rTs[0], timestamps[1]);
        assertEq(rTs[1], timestamps[1]);
        assertEq(rTs[2], timestamps[0]);
    }

    /*
     * Revert when at least one requested identifier is missing from the verified payload
     */
    function test_getVerifiedFeedDataBatchTransient_Revert_AnyUnmatched() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = 0xdeadbeef; // Missing target

        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchTransient.selector,
            requestedIds
        );

        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, requestedIds[1]));

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert when batch request contains at least one identifier with expired timestamp
     */
    function test_getVerifiedFeedDataBatchTransient_Revert_PartialExpired() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        uint256 currentTimestamp = block.timestamp;
        // Define an expired timestamp that exceeds the 180s limit
        uint256 expiredTimestamp = currentTimestamp - 181;

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            // Set ids[2] as expired to trigger failure
            timestamps[i] = i == 2 ? expiredTimestamp : currentTimestamp;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[2]; // Target expired package
        requestedIds[1] = ids[0]; // Target valid package

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchTransient.selector,
            requestedIds
        );
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                requestedIds[0],
                expiredTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert when batch request contains an identifier exceeding future drift tolerance
     */
    function test_getVerifiedFeedDataBatchTransient_Revert_PartialFutureDrift() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        uint256 currentTimestamp = block.timestamp;
        // Define future timestamp exceeding 60s drift limit
        uint256 futureTimestamp = currentTimestamp + 61;

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            // Assign future drifting timestamp to index 2
            timestamps[i] = i == 2 ? futureTimestamp : currentTimestamp;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[2]; // Target future package
        requestedIds[1] = ids[0]; // Target valid package

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchTransient.selector,
            requestedIds
        );
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                requestedIds[0],
                futureTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert if batch payload integrity is compromised via bit-flipping
     */
    function test_getVerifiedFeedDataBatchTransient_Revert_TamperedData() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[2];
        requestedIds[1] = ids[0];

        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        // Flip bit to invalidate cryptographic integrity before search execution
        extraData[0] ^= 0x01;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchTransient.selector,
            requestedIds
        );

        vm.expectPartialRevert(IPullOracleBase.UnauthorizedSigner.selector);

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify empty feedIds array short-circuits before authentication and returns empty arrays
     */
    function test_getVerifiedFeedDataBatchTransient_Success_EmptyFeedIds() public {
        bytes4[] memory emptyIds = new bytes4[](0);

        // No extraData appended — authentication must not execute
        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatchTransient.selector, emptyIds);

        (bool success, bytes memory returnData) = address(mock).call(businessCall);
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices.length, 0);
        assertEq(rTs.length, 0);
    }

    /* ————————————————————————————————————————————————————————————————————————
                            INTERNAL API (TRANSIENT): LENIENT BATCH
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify batch lenient retrieval handles mixed presence by returning zeros for missing identifiers
     */
    function test_getVerifiedFeedDataBatchLenientTransient_Success_Mixed() public {
        uint256 count = 3;

        uint256 currentTs = block.timestamp;
        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        // Populate payload with unique price and timestamp pairs to ensure extraction precision
        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = currentTs - i;
            unchecked {
                ++i;
            }
        }

        // Request one valid present ID and one non-existent ID
        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[1];
        requestedIds[1] = 0xdeadbeef;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchLenientTransient.selector,
            requestedIds
        );
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));

        // Assert valid data is returned for index 0 and zero fallback for index 1
        assertEq(rPrices[0], prices[1]);
        assertEq(rTs[0], timestamps[1]);
        assertEq(rPrices[1], 0);
        assertEq(rTs[1], 0);
    }

    /*
     * Verify lenient batch handles duplicate missing identifiers by returning multiple zero-fallbacks
     */
    function test_getVerifiedFeedDataBatchLenientTransient_Success_DuplicateMissingIDs() public {
        uint256 count = 3;

        uint256 currentTs = block.timestamp;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = currentTs - i;
            unchecked {
                ++i;
            }
        }

        bytes4 missingId = 0xdeadbeef;
        bytes4[] memory requestedIds = new bytes4[](3);
        requestedIds[0] = missingId;
        requestedIds[1] = ids[2];
        requestedIds[2] = missingId; // Duplicate missing ID

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchLenientTransient.selector,
            requestedIds
        );
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));

        // Verify index 0 and 2 are zeroed while index 1 is correctly resolved
        assertEq(rPrices[0], 0);
        assertEq(rPrices[1], prices[2]);
        assertEq(rPrices[2], 0);
        assertEq(rTs[0], 0);
        assertEq(rTs[1], timestamps[2]);
        assertEq(rTs[2], 0);
    }

    /*
     * Revert when batch lenient request contains at least one expired identifier
     */
    function test_getVerifiedFeedDataBatchLenientTransient_Revert_PartialExpired() public {
        uint256 count = 3;

        uint256 currentTs = block.timestamp;
        uint256 expiredTs = currentTs - 181;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            // Corrupt the third package with an expired timestamp
            timestamps[i] = i == 2 ? expiredTs : currentTs - i;
            unchecked {
                ++i;
            }
        }

        // Request one valid and one expired identifier to trigger mandatory revert
        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[2];

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchLenientTransient.selector,
            requestedIds
        );
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                requestedIds[1],
                expiredTs,
                currentTs
            )
        );

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert when batch lenient request contains an identifier exceeding future drift tolerance
     */
    function test_getVerifiedFeedDataBatchLenientTransient_Revert_PartialFutureDrift() public {
        uint256 count = 3;

        uint256 currentTs = block.timestamp;
        uint256 futureTs = currentTs + 61;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            // Inject future drift into the second package
            timestamps[i] = i == 1 ? futureTs : currentTs - i;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchLenientTransient.selector,
            requestedIds
        );
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                requestedIds[1],
                futureTs,
                currentTs
            )
        );

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert if batch payload integrity is compromised via bit-flipping
     */
    function test_getVerifiedFeedDataBatchLenientTransient_Revert_TamperedData() public {
        uint256 count = 3;

        uint256 currentTs = block.timestamp;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = currentTs - i;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        // Flip bit to invalidate cryptographic integrity before search execution
        extraData[0] ^= 0x01;

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatchLenientTransient.selector, ids);

        vm.expectPartialRevert(IPullOracleBase.UnauthorizedSigner.selector);

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify empty feedIds array short-circuits before authentication and returns empty arrays
     */
    function test_getVerifiedFeedDataBatchLenientTransient_Success_EmptyFeedIds() public {
        bytes4[] memory emptyIds = new bytes4[](0);

        // No extraData appended — authentication must not execute
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getVerifiedFeedDataBatchLenientTransient.selector,
            emptyIds
        );

        (bool success, bytes memory returnData) = address(mock).call(businessCall);
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices.length, 0);
        assertEq(rTs.length, 0);
    }

    /* ————————————————————————————————————————————————————————————————————————
                    FEED ID VALIDATION: FOREIGN TRANSIENT DATA REJECTION
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify that strict mode rejects foreign transient data whose high 4 bytes do not match
     * the requested feed ID. This guards against cross-logic slot collision within the same tx.
     */
    function test_strictBatch_Revert_ForeignTransientDataRejected() public {
        uint256 payloadCount = 3;

        bytes4 targetId = 0xAAAAAAAA;
        bytes4 presentId1 = 0xBBBBBBBB;
        bytes4 presentId2 = 0xCCCCCCCC;

        // Build a payload that does NOT contain targetId
        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        payloadIds[0] = presentId1;
        payloadIds[1] = presentId2;
        payloadIds[2] = bytes4(0xDDDDDDDD);
        for (uint256 i = 0; i < payloadCount; ) {
            payloadPrices[i] = (i + 1) * 100e18;
            payloadTimestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        // Construct a foreign word that has a DIFFERENT feed ID in the high 4 bytes
        // This simulates another contract's TSTORE writing to the same slot key
        bytes32 foreignWord = bytes32(uint256(bytes32(bytes4(0xEEEEEEEE))) | (999e18 << 144) | (block.timestamp << 96));

        bytes4[] memory poisonedIds = new bytes4[](1);
        poisonedIds[0] = targetId; // Poison the slot keyed by targetId

        bytes4[] memory requestedIds = new bytes4[](1);
        requestedIds[0] = targetId;

        // Layout: Selector(4) + offset_poisonedIds(32) + foreignWord(32) + offset_feedIds(32) +
        //         payloadStart(32) + payloadEnd(32) + poisonedIds_len(32) + poisonedIds_data(32) +
        //         feedIds_len(32) + feedIds_data(32)
        uint256 payloadStart = 4 + (32 * 9);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.strictBatchWithForeignTransientData.selector,
            poisonedIds,
            foreignWord,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        // The foreign word has feedId 0xEEEEEEEE in high bytes, but slot key is 0xAAAAAAAA
        // Validation must reject it, and since targetId is also absent from the real payload,
        // it should revert with UnmatchedFeedID
        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, targetId));

        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify that lenient mode returns zero for slots containing foreign transient data
     * whose high 4 bytes do not match the requested feed ID.
     */
    function test_lenientBatch_Success_ForeignTransientDataReturnsZero() public {
        uint256 payloadCount = 3;

        bytes4 targetId = 0xAAAAAAAA;
        bytes4 presentId1 = 0xBBBBBBBB;
        bytes4 presentId2 = 0xCCCCCCCC;

        // Build a payload that does NOT contain targetId but DOES contain presentId1
        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        payloadIds[0] = presentId1;
        payloadIds[1] = presentId2;
        payloadIds[2] = bytes4(0xDDDDDDDD);
        for (uint256 i = 0; i < payloadCount; ) {
            payloadPrices[i] = (i + 1) * 100e18;
            payloadTimestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        // Foreign word with mismatched feed ID in high 4 bytes
        bytes32 foreignWord = bytes32(uint256(bytes32(bytes4(0xEEEEEEEE))) | (999e18 << 144) | (block.timestamp << 96));

        bytes4[] memory poisonedIds = new bytes4[](1);
        poisonedIds[0] = targetId;

        // Request both the poisoned ID and a legitimately present ID
        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = targetId;
        requestedIds[1] = presentId1;

        // Layout: Selector(4) + offset_poisonedIds(32) + foreignWord(32) + offset_feedIds(32) +
        //         payloadStart(32) + payloadEnd(32) + poisonedIds_len(32) + poisonedIds_data(32) +
        //         feedIds_len(32) + feedIds_data(2*32)
        uint256 payloadStart = 4 + (32 * 10);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.lenientBatchWithForeignTransientData.selector,
            poisonedIds,
            foreignWord,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory prices, uint256[] memory ts) = abi.decode(returnData, (uint256[], uint256[]));

        // targetId: foreign data rejected by validation → returns (0, 0)
        assertEq(prices[0], 0, "Foreign transient data must be rejected: price should be 0");
        assertEq(ts[0], 0, "Foreign transient data must be rejected: timestamp should be 0");

        // presentId1: legitimate cache hit → returns real values
        assertEq(prices[1], payloadPrices[0], "Legitimate feed should return correct price");
        assertEq(ts[1], payloadTimestamps[0], "Legitimate feed should return correct timestamp");
    }

    /*
     * Verify that when foreign transient data happens to have the CORRECT feed ID in its high
     * 4 bytes (matching the slot key), it is accepted as a valid cache hit. This documents the
     * boundary condition: the validation only rejects mismatched feed IDs, not all foreign data.
     */
    function test_strictBatch_Success_ForeignDataWithMatchingFeedIdIsAccepted() public {
        uint256 payloadCount = 2;

        bytes4 targetId = 0xAAAAAAAA;

        // Build a payload that does NOT contain targetId
        bytes4[] memory payloadIds = new bytes4[](payloadCount);
        uint256[] memory payloadPrices = new uint256[](payloadCount);
        uint256[] memory payloadTimestamps = new uint256[](payloadCount);

        payloadIds[0] = bytes4(0xBBBBBBBB);
        payloadIds[1] = bytes4(0xCCCCCCCC);
        for (uint256 i = 0; i < payloadCount; ) {
            payloadPrices[i] = (i + 1) * 100e18;
            payloadTimestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        // Foreign word with MATCHING feed ID in high 4 bytes — passes the eq() check
        uint256 fakePrice = 777e18;
        uint256 fakeTimestamp = block.timestamp;
        bytes32 foreignWord = bytes32(uint256(bytes32(targetId)) | (fakePrice << 144) | (fakeTimestamp << 96));

        bytes4[] memory poisonedIds = new bytes4[](1);
        poisonedIds[0] = targetId;

        bytes4[] memory requestedIds = new bytes4[](1);
        requestedIds[0] = targetId;

        // Layout: Selector(4) + offset_poisonedIds(32) + foreignWord(32) + offset_feedIds(32) +
        //         payloadStart(32) + payloadEnd(32) + poisonedIds_len(32) + poisonedIds_data(32) +
        //         feedIds_len(32) + feedIds_data(32)
        uint256 payloadStart = 4 + (32 * 9);
        uint256 payloadEnd = payloadStart + payloadCount * 20;

        bytes memory businessCall = abi.encodeWithSelector(
            mock.strictBatchWithForeignTransientData.selector,
            poisonedIds,
            foreignWord,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory prices, uint256[] memory ts) = abi.decode(returnData, (uint256[], uint256[]));

        // The foreign word has the correct feed ID prefix — it passes validation
        // This documents the limitation: matching-prefix foreign data is indistinguishable
        assertEq(prices[0], fakePrice, "Foreign data with matching feedId prefix passes validation");
        assertEq(ts[0], fakeTimestamp, "Foreign data with matching feedId prefix passes validation");
    }

    /**
     * Assemble the high 160 bits (20 bytes) of a package for physical comparison
     * Matches the bitwise layout: [ID (32b) | Price (80b) | Timestamp (48b) | Padding zeros (96b)]
     */
    function _encodeLeftAlignedPackage(bytes4 id, uint256 price, uint256 ts) internal pure returns (bytes32) {
        return bytes32(uint256(bytes32(id)) | (price << 144) | (ts << 96));
    }
}
