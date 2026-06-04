// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {IPullOracleBase} from "interfaces/IPullOracleBase.sol";
import {IPullOracleReferenceHooks} from "interfaces/IPullOracleReferenceHooks.sol";
import {BaseTest} from "test/utils/BaseTest.t.sol";
import {PullOracleConsumerBaseMock} from "test/mocks/PullOracleConsumerBaseMock.sol";
import {LowLevelReverter} from "test/utils/LowLevelReverter.sol";

/*
 * Verify the assembly-based search algorithms for single feed retrieval with unique data fingerprints
 */
contract PullOracleConsumerBaseTest is BaseTest {
    using LowLevelReverter for address;

    PullOracleConsumerBaseMock internal mock = new PullOracleConsumerBaseMock();

    bytes4 internal constant TARGET_ID = 0x11223344;
    uint256 internal constant TARGET_PRICE = 50000e18;

    function setUp() public virtual {
        vm.warp(1 days);
    }

    /* ————————————————————————————————————————————————————————————————————————
                            STRICT MODE: SINGLE SEARCH
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate successful identification and decoding when the target ID exists in the payload
     */
    function test_getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched_Success() public view {
        uint256 count = 3;
        uint256 targetIndex = 2;

        // Define distinct timestamps to verify correct word retrieval
        uint256 targetTimestamp = block.timestamp;
        uint256 dummyTimestamp = block.timestamp - 10;

        // Initialize parallel arrays using the predefined count
        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        // Populate arrays with target data at targetIndex and unique dummy data elsewhere
        for (uint256 i = 0; i < count; ) {
            if (i == targetIndex) {
                ids[i] = TARGET_ID;
                prices[i] = TARGET_PRICE;
                timestamps[i] = targetTimestamp;
            } else {
                ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
                prices[i] = 100e18; // Different price for dummy
                timestamps[i] = dummyTimestamp; // Different timestamp for dummy
            }
            unchecked {
                ++i;
            }
        }

        // Define physical offset: 4B (Selector) + 3 * 32B (Parameters) = 100B
        uint256 payloadStart = 100;
        uint256 payloadEnd = payloadStart + count * 20;
        // Construct business calldata targeting the strict search function
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched.selector,
            TARGET_ID,
            payloadStart,
            payloadEnd
        );

        // Build extra data without signing to verify search engine logic
        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        // Execute staticcall with attached extraData to simulate full calldata layout
        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));

        assertEq(price, TARGET_PRICE);
        assertEq(ts, targetTimestamp);
    }

    /*
     * Verify revert with UnmatchedFeedID when the requested ID is absent from the payload
     */
    function test_getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched_Revert_UnmatchedFeedID() public {
        uint256 count = 4;
        bytes4 missingId = TARGET_ID;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        // Define physical offset: 4B (Selector) + 3 * 32B (Parameters) = 100B
        uint256 payloadStart = 100;
        uint256 payloadEnd = payloadStart + count * 20;
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched.selector,
            missingId,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, missingId));

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify revert when the requested ID is located but its timestamp fails freshness validation
     */
    function test_getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched_Revert_PriceFeedExpired() public {
        uint256 count = 4;
        uint256 targetIndex = 2;
        uint256 currentTimestamp = block.timestamp;

        // Define an expired timestamp that exceeds the default 180s limit
        uint256 expiredTimestamp = currentTimestamp - 181;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            if (i == targetIndex) {
                ids[i] = TARGET_ID;
                prices[i] = TARGET_PRICE;
                timestamps[i] = expiredTimestamp;
            } else {
                ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
                prices[i] = 100e18;
                timestamps[i] = currentTimestamp;
            }
            unchecked {
                ++i;
            }
        }

        // Define physical offset: 4B (Selector) + 3 * 32B (Parameters) = 100B
        uint256 payloadStart = 100;
        uint256 payloadEnd = payloadStart + count * 20;
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched.selector,
            TARGET_ID,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                TARGET_ID,
                expiredTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify revert when the requested ID is located but its timestamp drifts too far into the future
     */
    function test_getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched_Revert_PriceFeedFutureDrift() public {
        uint256 count = 4;
        uint256 targetIndex = 1;
        uint256 currentTimestamp = block.timestamp;

        // Define a future timestamp that exceeds the default 60s drift limit
        uint256 futureTimestamp = currentTimestamp + 61;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            if (i == targetIndex) {
                ids[i] = TARGET_ID;
                prices[i] = TARGET_PRICE;
                timestamps[i] = futureTimestamp;
            } else {
                ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
                prices[i] = 100e18;
                timestamps[i] = currentTimestamp;
            }
            unchecked {
                ++i;
            }
        }

        // Define physical offset: 4B (Selector) + 3 * 32B (Parameters) = 100B
        uint256 payloadStart = 100;
        uint256 payloadEnd = payloadStart + count * 20;
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched.selector,
            TARGET_ID,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                TARGET_ID,
                futureTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            STRICT MODE: BATCH SEARCH
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate successful batch retrieval and memory allocation for multiple requested IDs
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched_Success() public view {
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

        // Layout: Selector(4) + offset_to_array(32) + payloadStart(32) + payloadEnd(32) + array_len(32) + 3*ids(96)
        uint256 payloadStart = 4 + 32 + 32 + 32 + 32 + (requestedIds.length * 32);

        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched.selector,
            requestedIds,
            payloadStart,
            payloadStart + payloadCount * 20
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
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
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched_Revert_PartialUnmatchedID() public {
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
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, requestedIds[1]));

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify revert when a specific ID within a batch fails freshness validation
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched_Revert_PartialExpired() public {
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
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched.selector,
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

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify revert when a specific ID within a batch drifts too far into the future
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched_Revert_PartialFutureDrift() public {
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
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched.selector,
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

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            LENIENT MODE: SINGLE SEARCH
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate successful identification in lenient mode when the target exists
     */
    function test_getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched_Success() public view {
        uint256 count = 3;
        uint256 targetIndex = 1; // Middle slot
        uint256 targetTimestamp = block.timestamp;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            if (i == targetIndex) {
                ids[i] = TARGET_ID;
                prices[i] = TARGET_PRICE;
                timestamps[i] = targetTimestamp;
            } else {
                ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
                prices[i] = 100e18;
                timestamps[i] = block.timestamp - 5;
            }
            unchecked {
                ++i;
            }
        }

        // Define physical offset: 4B (Selector) + 3 * 32B (Parameters) = 100B
        uint256 payloadStart = 100;
        uint256 payloadEnd = payloadStart + count * 20;
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched.selector,
            TARGET_ID,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, TARGET_PRICE);
        assertEq(ts, targetTimestamp);
    }

    /*
     * Verify the function returns zero values instead of reverting when the ID is unmatched
     */
    function test_getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched_ReturnZero_IfUnmatched() public view {
        uint256 count = 3;
        bytes4 missingId = 0xdeadbeef;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        // Define physical offset: 4B (Selector) + 3 * 32B (Parameters) = 100B
        uint256 payloadStart = 100;
        uint256 payloadEnd = payloadStart + count * 20;
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched.selector,
            missingId,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, 0);
        assertEq(ts, 0);
    }

    /*
     * Ensure lenient mode still reverts if the target ID is found but its timestamp is expired
     */
    function test_getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched_Revert_PriceFeedExpired() public {
        uint256 count = 4;
        uint256 targetIndex = 2;
        uint256 currentTimestamp = block.timestamp;

        // Define an expired timestamp that exceeds the 180s limit
        uint256 expiredTimestamp = currentTimestamp - 181;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        // Populate payload with an expired target at index 2
        for (uint256 i = 0; i < count; ) {
            if (i == targetIndex) {
                ids[i] = TARGET_ID;
                prices[i] = TARGET_PRICE;
                timestamps[i] = expiredTimestamp;
            } else {
                ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
                prices[i] = 100e18;
                timestamps[i] = currentTimestamp;
            }
            unchecked {
                ++i;
            }
        }

        // Define physical offset: 4B (Selector) + 3 * 32B (Parameters) = 100B
        uint256 payloadStart = 100;
        uint256 payloadEnd = payloadStart + count * 20;
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched.selector,
            TARGET_ID,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                TARGET_ID,
                expiredTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Ensure lenient mode still reverts if the target ID is found but its timestamp drifts into the future
     */
    function test_getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched_Revert_PriceFeedFutureDrift() public {
        uint256 count = 4;
        uint256 targetIndex = 3;
        uint256 currentTimestamp = block.timestamp;

        // Define a future timestamp that exceeds the 60s drift limit
        uint256 futureTimestamp = currentTimestamp + 61;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        // Populate payload with a future-drifting target at index 1
        for (uint256 i = 0; i < count; ) {
            if (i == targetIndex) {
                ids[i] = TARGET_ID;
                prices[i] = TARGET_PRICE;
                timestamps[i] = futureTimestamp;
            } else {
                ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
                prices[i] = 100e18;
                timestamps[i] = currentTimestamp;
            }
            unchecked {
                ++i;
            }
        }

        // Define physical offset: 4B (Selector) + 3 * 32B (Parameters) = 100B
        uint256 payloadStart = 100;
        uint256 payloadEnd = payloadStart + count * 20;
        bytes memory businessCall = abi.encodeWithSelector(
            mock.getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched.selector,
            TARGET_ID,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                TARGET_ID,
                futureTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            LENIENT MODE: BATCH SEARCH
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate batch retrieval in lenient mode where missing IDs result in zero values instead of reverts
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched_Success_PartialMissing() public view {
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
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
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
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched_Success_AllMissing() public view {
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
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched.selector,
            requestedIds,
            payloadStart,
            payloadEnd
        );

        bytes memory extraData = _buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
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
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched_Revert_PartialExpired() public {
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
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched.selector,
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

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Ensure lenient batch search still reverts if a matched ID drifts into the future
     */
    function test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched_Revert_PartialFutureDrift() public {
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
            mock.getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched.selector,
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

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            AUTHENTICATION
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate the complete authentication flow including signature recovery and signer authorization
     */
    function test_authenticateAndUnpackExtraData_Success() public view {
        uint256 count = 3;
        uint256 currentTimestamp = block.timestamp;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        // Populate arrays with distinct data to generate a unique signing digest
        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = currentTimestamp - i;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);

        bytes memory businessCall = abi.encodeWithSelector(mock.authenticateAndUnpackExtraData.selector);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256 payloadStart, uint256 decodedPayloadEnd) = abi.decode(returnData, (uint256, uint256));

        // Define expected offset: 4B (Selector) as the wrapper function has no arguments
        // The extraData starts immediately after the business call's function selector
        uint256 expectedPayloadStart = 4;
        assertEq(payloadStart, expectedPayloadStart);
        assertEq(decodedPayloadEnd, expectedPayloadStart + count * 20);
    }

    /*
     * Verify that the gateway correctly identifies extraData even when separated from the
     * selector by arbitrary junk data, proving tail-relative indexing robustness
     */
    function test_authenticateAndUnpackExtraData_Success_WithJunkData() public view {
        uint256 count = 2;
        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);

        // Construct junk data
        bytes memory junk = bytes("unaligned_junk_17");

        // Assemble payload: [Selector (4B)][Junk (17B)][ExtraData (Tail)]
        bytes memory selector = abi.encodeWithSelector(mock.authenticateAndUnpackExtraData.selector);
        bytes memory fullPayload = abi.encodePacked(selector, junk, extraData);

        (bool success, bytes memory returnData) = address(mock).staticcall(fullPayload);
        assertTrue(success);

        (uint256 payloadStart, uint256 decodedPayloadEnd) = abi.decode(returnData, (uint256, uint256));

        // Verify the dynamic offset accommodates the 17-byte shift (4 + 17 = 21)
        uint256 expectedPayloadStart = 4 + junk.length;
        assertEq(payloadStart, expectedPayloadStart);
        assertEq(decodedPayloadEnd, expectedPayloadStart + count * 20);
    }

    /*
     * Verify revert when the payload is signed by an unauthorized signer
     */
    function test_authenticateAndUnpackExtraData_Revert_UnauthorizedSigner() public {
        uint256 count = 2;
        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        // Sign using the unauthorized private key
        bytes memory extraData = _buildSignedExtraData(UNAUTHORIZED_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(mock.authenticateAndUnpackExtraData.selector);

        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnauthorizedSigner.selector, UNAUTHORIZED_SIGNER));

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify revert when even a single bit of signed data is tampered with, causing signature mismatch
     */
    function test_authenticateAndUnpackExtraData_Revert_TamperedData() public {
        uint256 count = 1;
        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        ids[0] = TARGET_ID;
        prices[0] = TARGET_PRICE;
        timestamps[0] = block.timestamp;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);

        // Flip a bit in the packages section to invalidate the cryptographic digest
        extraData[0] = extraData[0] ^ 0x01;

        bytes memory businessCall = abi.encodeWithSelector(mock.authenticateAndUnpackExtraData.selector);

        // Expect UnauthorizedSigner selector as tampering results in a non-deterministic random address
        // This ignores the random address parameter generated by ecrecover upon tampering
        vm.expectPartialRevert(IPullOracleBase.UnauthorizedSigner.selector);

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify revert when the magic marker is corrupted, causing the codec to fail metadata parsing
     */
    function test_authenticateAndUnpackExtraData_Revert_InvalidMagicMarker() public {
        uint256 count = 1;
        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        ids[0] = TARGET_ID;
        prices[0] = TARGET_PRICE;
        timestamps[0] = block.timestamp;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);

        // Perform a minimal bitwise flip on the last byte to invalidate the marker
        extraData[extraData.length - 1] = extraData[extraData.length - 1] ^ 0x01;

        bytes memory businessCall = abi.encodeWithSelector(mock.authenticateAndUnpackExtraData.selector);

        vm.expectRevert(IPullOracleBase.InvalidMarker.selector);

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            INTERNAL API: STRICT SINGLE
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate the successful integration of authentication and strict search
     */
    function test_getVerifiedFeedData_Success() public view {
        uint256 count = 3;
        uint256 targetIndex = 1; // Target is placed in the middle
        uint256 currentTs = block.timestamp;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        // Populate payload with dummy data and the specific TARGET_ID at index 1
        for (uint256 i = 0; i < count; ) {
            if (i == targetIndex) {
                ids[i] = TARGET_ID;
                prices[i] = TARGET_PRICE;
                timestamps[i] = currentTs;
            } else {
                ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
                prices[i] = (i + 1) * 100e18;
                timestamps[i] = currentTs - i;
            }
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedData.selector, TARGET_ID);
        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));

        assertEq(price, TARGET_PRICE);
        assertEq(ts, currentTs);
    }

    /*
     * Validate strict single retrieval revert for missing identifiers within multi-package payload
     */
    function test_getVerifiedFeedData_Revert_UnmatchedFeedID() public {
        uint256 count = 3;
        bytes4 missingId = 0xdeadbeef;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedData.selector, missingId);

        vm.expectPartialRevert(IPullOracleBase.UnmatchedFeedID.selector);

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert if signature-protected data is tampered with
     */
    function test_getVerifiedFeedData_Revert_TamperedData() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        // Flip a single bit in the payload to invalidate the cryptographic signature
        extraData[0] = extraData[0] ^ 0x01;

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedData.selector, ids[0]);
        // Expect UnauthorizedSigner as tampering causes ecrecover to yield a random address
        vm.expectPartialRevert(IPullOracleBase.UnauthorizedSigner.selector);

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert when single requested feed contains an expired timestamp
     */
    function test_getVerifiedFeedData_Revert_Expired() public {
        uint256 count = 3;
        uint256 targetIndex = 1;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        uint256 currentTimestamp = block.timestamp;
        uint256 expiredTimestamp = currentTimestamp - 181;

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            // Set target package as expired to trigger single point failure
            timestamps[i] = i == targetIndex ? expiredTimestamp : currentTimestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedData.selector, ids[targetIndex]);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                ids[targetIndex],
                expiredTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert when single requested feed exceeds future drift tolerance
     */
    function test_getVerifiedFeedData_Revert_FutureDrift() public {
        uint256 count = 3;
        uint256 targetIndex = 1;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        uint256 currentTimestamp = block.timestamp;
        uint256 futureTimestamp = currentTimestamp + 61;

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            // Assign future drifting timestamp to target index
            timestamps[i] = i == targetIndex ? futureTimestamp : currentTimestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedData.selector, ids[targetIndex]);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                ids[targetIndex],
                futureTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            INTERNAL API: STRICT BATCH
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Validate integrated batch retrieval for multiple identifiers within a verified payload
     */
    function test_getVerifiedFeedDataBatch_Success() public view {
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

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatch.selector, requestedIds);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
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
    function test_getVerifiedFeedDataBatch_Success_DuplicateRequestedIDs() public view {
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

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatch.selector, requestedIds);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
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
    function test_getVerifiedFeedDataBatch_Revert_AnyUnmatched() public {
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

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatch.selector, requestedIds);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, requestedIds[1]));

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert when batch request contains at least one identifier with expired timestamp
     */
    function test_getVerifiedFeedDataBatch_Revert_PartialExpired() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        uint256 currentTimestamp = block.timestamp;
        // Define an expired timestamp exceeding the 180s limit
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

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatch.selector, requestedIds);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                requestedIds[0],
                expiredTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert when batch request contains an identifier exceeding future drift tolerance
     */
    function test_getVerifiedFeedDataBatch_Revert_PartialFutureDrift() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        uint256 currentTimestamp = block.timestamp;
        uint256 futureTimestamp = currentTimestamp + 61;

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = i == 2 ? futureTimestamp : currentTimestamp;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[2];
        requestedIds[1] = ids[0];

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatch.selector, requestedIds);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                requestedIds[0],
                futureTimestamp,
                currentTimestamp
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    function test_getVerifiedFeedDataBatch_Revert_TamperedData() public {
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
        extraData[0] ^= 0x01;

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatch.selector, requestedIds);
        vm.expectPartialRevert(IPullOracleBase.UnauthorizedSigner.selector);
        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    function test_getVerifiedFeedDataBatch_Success_EmptyFeedIds() public view {
        bytes4[] memory emptyIds = new bytes4[](0);
        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatch.selector, emptyIds);
        (bool success, bytes memory returnData) = address(mock).staticcall(businessCall);
        assertTrue(success);
        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices.length, 0);
        assertEq(rTs.length, 0);
    }

    /* ————————————————————————————————————————————————————————————————————————
                            INTERNAL API: LENIENT SINGLE
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify successful integration of authentication and lenient single search
     */
    function test_getVerifiedFeedDataLenient_Success() public view {
        uint256 count = 3;
        uint256 targetIndex = 1;
        uint256 currentTs = block.timestamp;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = i == targetIndex ? TARGET_ID : bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = currentTs - i;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataLenient.selector, TARGET_ID);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, prices[targetIndex]);
        assertEq(ts, currentTs - targetIndex);
    }

    /*
     * Return zero values when the requested identifier is missing from the verified payload
     */
    function test_getVerifiedFeedDataLenient_Zero_Unmatched() public view {
        uint256 count = 3;
        bytes4 missingId = 0xdeadbeef;
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
        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataLenient.selector, missingId);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, 0);
        assertEq(ts, 0);
    }

    /*
     * Revert on expired feed timestamp even in lenient mode
     */
    function test_getVerifiedFeedDataLenient_Revert_Expired() public {
        uint256 count = 3;
        uint256 targetIndex = 1;
        uint256 currentTs = block.timestamp;
        uint256 expiredTs = currentTs - 181;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = i == targetIndex ? expiredTs : currentTs - i;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataLenient.selector, ids[targetIndex]);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                ids[targetIndex],
                expiredTs,
                currentTs
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert on future drifting timestamp even in lenient mode
     */
    function test_getVerifiedFeedDataLenient_Revert_FutureDrift() public {
        uint256 count = 3;
        uint256 targetIndex = 1;
        uint256 currentTs = block.timestamp;
        uint256 futureTs = currentTs + 61;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = i == targetIndex ? futureTs : currentTs - i;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataLenient.selector, ids[targetIndex]);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                ids[targetIndex],
                futureTs,
                currentTs
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert if payload integrity is compromised via bit-flipping
     */
    function test_getVerifiedFeedDataLenient_Revert_TamperedData() public {
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
        extraData[0] ^= 0x01;
        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataLenient.selector, ids[0]);
        vm.expectPartialRevert(IPullOracleBase.UnauthorizedSigner.selector);
        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            INTERNAL API: LENIENT BATCH
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify batch lenient retrieval handles mixed presence by returning zeros for missing identifiers
     */
    function test_getVerifiedFeedDataBatchLenient_Success_Mixed() public view {
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

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[1];
        requestedIds[1] = 0xdeadbeef;

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatchLenient.selector, requestedIds);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));

        assertEq(rPrices[0], prices[1]);
        assertEq(rTs[0], timestamps[1]);
        assertEq(rPrices[1], 0);
        assertEq(rTs[1], 0);
    }

    /*
     * Verify lenient batch handles duplicate missing identifiers by returning multiple zero-fallbacks
     */
    function test_getVerifiedFeedDataBatchLenient_Success_DuplicateMissingIDs() public view {
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

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatchLenient.selector, requestedIds);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        (bool success, bytes memory returnData) = address(mock).staticcall(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));

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
    function test_getVerifiedFeedDataBatchLenient_Revert_PartialExpired() public {
        uint256 count = 3;
        uint256 currentTs = block.timestamp;
        uint256 expiredTs = currentTs - 181;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = i == 2 ? expiredTs : currentTs - i;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[2];

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatchLenient.selector, requestedIds);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                requestedIds[1],
                expiredTs,
                currentTs
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert when batch lenient request contains an identifier exceeding future drift tolerance
     */
    function test_getVerifiedFeedDataBatchLenient_Revert_PartialFutureDrift() public {
        uint256 count = 3;
        uint256 currentTs = block.timestamp;
        uint256 futureTs = currentTs + 61;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("dummy", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = i == 1 ? futureTs : currentTs - i;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatchLenient.selector, requestedIds);
        bytes memory extraData = _buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                requestedIds[1],
                futureTs,
                currentTs
            )
        );

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Revert if batch payload integrity is compromised via bit-flipping
     */
    function test_getVerifiedFeedDataBatchLenient_Revert_TamperedData() public {
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
        extraData[0] ^= 0x01;

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatchLenient.selector, ids);

        vm.expectPartialRevert(IPullOracleBase.UnauthorizedSigner.selector);

        address(mock).revertingStaticcall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify empty feedIds array short-circuits before authentication and returns empty arrays
     */
    function test_getVerifiedFeedDataBatchLenient_Success_EmptyFeedIds() public view {
        bytes4[] memory emptyIds = new bytes4[](0);

        bytes memory businessCall = abi.encodeWithSelector(mock.getVerifiedFeedDataBatchLenient.selector, emptyIds);

        (bool success, bytes memory returnData) = address(mock).staticcall(businessCall);
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices.length, 0);
        assertEq(rTs.length, 0);
    }
}
