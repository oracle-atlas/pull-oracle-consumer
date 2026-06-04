// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {BaseTest} from "test/utils/BaseTest.t.sol";
import {LowLevelReverter} from "test/utils/LowLevelReverter.sol";
import {PullOracleConsumerStandardStorageMock} from "test/mocks/PullOracleConsumerStandardStorageMock.sol";
import {IPullOracleConsumerStorage} from "interfaces/IPullOracleConsumerStorage.sol";
import {IPullOracleReferenceHooks} from "interfaces/IPullOracleReferenceHooks.sol";
import {IPullOracleBase} from "interfaces/IPullOracleBase.sol";

/*
 * Test suite for PullOracleConsumerStandardStorage
 */
contract PullOracleConsumerStandardStorageTest is BaseTest {
    using LowLevelReverter for address;

    event MaxPackageCountUpdated(uint256 oldValue, uint256 newValue);
    event MaxDelayUpdated(uint256 oldValue, uint256 newValue);
    event MaxFutureDriftUpdated(uint256 oldValue, uint256 newValue);
    event SignerStatusUpdated(address indexed signer, bool authorized);

    PullOracleConsumerStandardStorageMock internal mock;

    uint8 internal constant INIT_COUNT = 10;
    uint48 internal constant INIT_DELAY = 60;
    uint48 internal constant INIT_DRIFT = 30;

    bytes4 internal constant TEST_FEED_ID = 0x01020304;
    uint256 internal constant TEST_PRICE = 50000e18;

    function setUp() public {
        vm.warp(1 days);

        address[] memory signers = new address[](2);
        signers[0] = PRIMARY_SIGNER;
        signers[1] = SECONDARY_SIGNER;

        mock = new PullOracleConsumerStandardStorageMock(INIT_COUNT, INIT_DELAY, INIT_DRIFT, signers);
    }

    /* ————————————————————————————————————————————————————————————————————————
                            CONSTRUCTOR TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify constructor correctly initializes config and signer set
     */
    function test_Constructor_InitializesState() public view {
        assertEq(mock.getMaxPackageCount(), uint256(INIT_COUNT));
        assertEq(mock.getMaxDelay(), uint256(INIT_DELAY));
        assertEq(mock.getMaxFutureDrift(), uint256(INIT_DRIFT));
        assertTrue(mock.isAuthorizedSigner(PRIMARY_SIGNER));
        assertTrue(mock.isAuthorizedSigner(SECONDARY_SIGNER));
        assertFalse(mock.isAuthorizedSigner(UNAUTHORIZED_SIGNER));
    }

    /*
     * Verify constructor emits SignerStatusUpdated for each initial signer
     */
    function test_Constructor_EmitsSignerEvents() public {
        address[] memory signers = new address[](2);
        signers[0] = PRIMARY_SIGNER;
        signers[1] = SECONDARY_SIGNER;

        vm.expectEmit(true, false, false, true);
        emit SignerStatusUpdated(PRIMARY_SIGNER, true);
        vm.expectEmit(true, false, false, true);
        emit SignerStatusUpdated(SECONDARY_SIGNER, true);

        new PullOracleConsumerStandardStorageMock(INIT_COUNT, INIT_DELAY, INIT_DRIFT, signers);
    }

    /*
     * Verify constructor allows zero maxFutureDrift (strict policy)
     */
    function test_Constructor_ZeroDrift_Allowed() public {
        address[] memory signers = new address[](1);
        signers[0] = PRIMARY_SIGNER;

        PullOracleConsumerStandardStorageMock m = new PullOracleConsumerStandardStorageMock(
            INIT_COUNT,
            INIT_DELAY,
            0,
            signers
        );
        assertEq(m.getMaxFutureDrift(), 0);
    }

    /*
     * Verify constructor allows empty signer array
     */
    function test_Constructor_EmptySigners_Allowed() public {
        PullOracleConsumerStandardStorageMock m = new PullOracleConsumerStandardStorageMock(
            INIT_COUNT,
            INIT_DELAY,
            INIT_DRIFT,
            new address[](0)
        );
        assertEq(m.getMaxPackageCount(), uint256(INIT_COUNT));
    }

    /*
     * Verify constructor reverts on zero maxPackageCount
     */
    function test_Revert_Constructor_ZeroMaxPackageCount() public {
        vm.expectRevert(IPullOracleConsumerStorage.InvalidMaxPackageCount.selector);
        new PullOracleConsumerStandardStorageMock(0, INIT_DELAY, INIT_DRIFT, new address[](0));
    }

    /*
     * Verify constructor reverts on zero maxDelay
     */
    function test_Revert_Constructor_ZeroMaxDelay() public {
        vm.expectRevert(IPullOracleConsumerStorage.InvalidMaxDelay.selector);
        new PullOracleConsumerStandardStorageMock(INIT_COUNT, 0, INIT_DRIFT, new address[](0));
    }

    /*
     * Verify constructor reverts on zero address in initial signers
     */
    function test_Revert_Constructor_ZeroAddressSigner() public {
        address[] memory signers = new address[](1);
        signers[0] = address(0);

        vm.expectRevert(IPullOracleConsumerStorage.ZeroAddressSigner.selector);
        new PullOracleConsumerStandardStorageMock(INIT_COUNT, INIT_DELAY, INIT_DRIFT, signers);
    }

    /*
     * Verify constructor reverts on duplicate signer in initial signers
     */
    function test_Revert_Constructor_DuplicateSigner() public {
        address[] memory signers = new address[](3);
        signers[0] = PRIMARY_SIGNER;
        signers[1] = SECONDARY_SIGNER;
        signers[2] = PRIMARY_SIGNER;

        vm.expectRevert(
            abi.encodeWithSelector(IPullOracleConsumerStorage.SignerStatusAlreadySet.selector, PRIMARY_SIGNER)
        );
        new PullOracleConsumerStandardStorageMock(INIT_COUNT, INIT_DELAY, INIT_DRIFT, signers);
    }

    /* ————————————————————————————————————————————————————————————————————————
                        CONFIG SETTER TESTS: maxPackageCount
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify setMaxPackageCount updates value and emits event
     */
    function test_SetMaxPackageCount_Success() public {
        uint8 newCount = 20;

        vm.expectEmit(false, false, false, true);
        emit MaxPackageCountUpdated(uint256(INIT_COUNT), uint256(newCount));

        mock.setMaxPackageCount(newCount);
        assertEq(mock.getMaxPackageCount(), uint256(newCount));
    }

    /*
     * Verify setMaxPackageCount does not corrupt other config fields
     */
    function test_SetMaxPackageCount_FieldIsolation() public {
        mock.setMaxPackageCount(20);
        assertEq(mock.getMaxDelay(), uint256(INIT_DELAY));
        assertEq(mock.getMaxFutureDrift(), uint256(INIT_DRIFT));
    }

    /*
     * Verify setMaxPackageCount reverts on zero
     */
    function test_Revert_SetMaxPackageCount_Zero() public {
        vm.expectRevert(IPullOracleConsumerStorage.InvalidMaxPackageCount.selector);
        mock.setMaxPackageCount(0);
    }

    /*
     * Verify setMaxPackageCount reverts when setting to current value
     */
    function test_Revert_SetMaxPackageCount_SameValue() public {
        vm.expectRevert(IPullOracleConsumerStorage.ConfigValueAlreadySet.selector);
        mock.setMaxPackageCount(INIT_COUNT);
    }

    /*
     * Fuzz: setMaxPackageCount roundtrip
     */
    function test_SetMaxPackageCount_Fuzz(uint8 newCount) public {
        vm.assume(newCount > 0);
        vm.assume(newCount != INIT_COUNT);
        mock.setMaxPackageCount(newCount);
        assertEq(mock.getMaxPackageCount(), uint256(newCount));
        assertEq(mock.getMaxDelay(), uint256(INIT_DELAY));
        assertEq(mock.getMaxFutureDrift(), uint256(INIT_DRIFT));
    }

    /* ————————————————————————————————————————————————————————————————————————
                        CONFIG SETTER TESTS: maxDelay
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify setMaxDelay updates value and emits event
     */
    function test_SetMaxDelay_Success() public {
        uint48 newDelay = 120;

        vm.expectEmit(false, false, false, true);
        emit MaxDelayUpdated(uint256(INIT_DELAY), uint256(newDelay));

        mock.setMaxDelay(newDelay);
        assertEq(mock.getMaxDelay(), uint256(newDelay));
    }

    /*
     * Verify setMaxDelay does not corrupt other config fields
     */
    function test_SetMaxDelay_FieldIsolation() public {
        mock.setMaxDelay(120);
        assertEq(mock.getMaxPackageCount(), uint256(INIT_COUNT));
        assertEq(mock.getMaxFutureDrift(), uint256(INIT_DRIFT));
    }

    /*
     * Verify setMaxDelay reverts on zero
     */
    function test_Revert_SetMaxDelay_Zero() public {
        vm.expectRevert(IPullOracleConsumerStorage.InvalidMaxDelay.selector);
        mock.setMaxDelay(0);
    }

    /*
     * Verify setMaxDelay reverts when setting to current value
     */
    function test_Revert_SetMaxDelay_SameValue() public {
        vm.expectRevert(IPullOracleConsumerStorage.ConfigValueAlreadySet.selector);
        mock.setMaxDelay(INIT_DELAY);
    }

    /*
     * Fuzz: setMaxDelay roundtrip
     */
    function test_SetMaxDelay_Fuzz(uint48 newDelay) public {
        vm.assume(newDelay > 0);
        vm.assume(newDelay != INIT_DELAY);
        mock.setMaxDelay(newDelay);
        assertEq(mock.getMaxDelay(), uint256(newDelay));
        assertEq(mock.getMaxPackageCount(), uint256(INIT_COUNT));
        assertEq(mock.getMaxFutureDrift(), uint256(INIT_DRIFT));
    }

    /* ————————————————————————————————————————————————————————————————————————
                        CONFIG SETTER TESTS: maxFutureDrift
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify setMaxFutureDrift updates value and emits event
     */
    function test_SetMaxFutureDrift_Success() public {
        uint48 newDrift = 90;

        vm.expectEmit(false, false, false, true);
        emit MaxFutureDriftUpdated(uint256(INIT_DRIFT), uint256(newDrift));

        mock.setMaxFutureDrift(newDrift);
        assertEq(mock.getMaxFutureDrift(), uint256(newDrift));
    }

    /*
     * Verify setMaxFutureDrift does not corrupt other config fields
     */
    function test_SetMaxFutureDrift_FieldIsolation() public {
        mock.setMaxFutureDrift(90);
        assertEq(mock.getMaxPackageCount(), uint256(INIT_COUNT));
        assertEq(mock.getMaxDelay(), uint256(INIT_DELAY));
    }

    /*
     * Verify setMaxFutureDrift accepts zero (strict policy)
     */
    function test_SetMaxFutureDrift_Zero_Allowed() public {
        mock.setMaxFutureDrift(0);
        assertEq(mock.getMaxFutureDrift(), 0);
    }

    /*
     * Verify setMaxFutureDrift reverts when setting to current value
     */
    function test_Revert_SetMaxFutureDrift_SameValue() public {
        vm.expectRevert(IPullOracleConsumerStorage.ConfigValueAlreadySet.selector);
        mock.setMaxFutureDrift(INIT_DRIFT);
    }

    /*
     * Fuzz: setMaxFutureDrift roundtrip
     */
    function test_SetMaxFutureDrift_Fuzz(uint48 newDrift) public {
        vm.assume(newDrift != INIT_DRIFT);
        mock.setMaxFutureDrift(newDrift);
        assertEq(mock.getMaxFutureDrift(), uint256(newDrift));
        assertEq(mock.getMaxPackageCount(), uint256(INIT_COUNT));
        assertEq(mock.getMaxDelay(), uint256(INIT_DELAY));
    }

    /* ————————————————————————————————————————————————————————————————————————
                        SIGNER MANAGEMENT TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify adding a new signer
     */
    function test_SetSignerStatus_Add() public {
        vm.expectEmit(true, false, false, true);
        emit SignerStatusUpdated(UNAUTHORIZED_SIGNER, true);

        mock.setSignerStatus(UNAUTHORIZED_SIGNER, true);
        assertTrue(mock.isAuthorizedSigner(UNAUTHORIZED_SIGNER));
    }

    /*
     * Verify removing an existing signer
     */
    function test_SetSignerStatus_Remove() public {
        vm.expectEmit(true, false, false, true);
        emit SignerStatusUpdated(PRIMARY_SIGNER, false);

        mock.setSignerStatus(PRIMARY_SIGNER, false);
        assertFalse(mock.isAuthorizedSigner(PRIMARY_SIGNER));
    }

    /*
     * Verify removing a signer does not affect other signers
     */
    function test_SetSignerStatus_Remove_Isolation() public {
        mock.setSignerStatus(PRIMARY_SIGNER, false);
        assertFalse(mock.isAuthorizedSigner(PRIMARY_SIGNER));
        assertTrue(mock.isAuthorizedSigner(SECONDARY_SIGNER));
    }

    /*
     * Verify revert when adding a signer that is already authorized
     */
    function test_Revert_SetSignerStatus_AlreadySet_Add() public {
        vm.expectRevert(
            abi.encodeWithSelector(IPullOracleConsumerStorage.SignerStatusAlreadySet.selector, PRIMARY_SIGNER)
        );
        mock.setSignerStatus(PRIMARY_SIGNER, true);
    }

    /*
     * Verify revert when removing a signer that is not authorized
     */
    function test_Revert_SetSignerStatus_AlreadySet_Remove() public {
        vm.expectRevert(
            abi.encodeWithSelector(IPullOracleConsumerStorage.SignerStatusAlreadySet.selector, UNAUTHORIZED_SIGNER)
        );
        mock.setSignerStatus(UNAUTHORIZED_SIGNER, false);
    }

    /*
     * Verify revert when adding zero address signer
     */
    function test_Revert_SetSignerStatus_ZeroAddress() public {
        vm.expectRevert(IPullOracleConsumerStorage.ZeroAddressSigner.selector);
        mock.setSignerStatus(address(0), true);
    }

    /*
     * Verify revert when removing zero address signer
     */
    function test_Revert_SetSignerStatus_ZeroAddress_Remove() public {
        vm.expectRevert(IPullOracleConsumerStorage.ZeroAddressSigner.selector);
        mock.setSignerStatus(address(0), false);
    }

    /*
     * Verify add then remove then re-add cycle
     */
    function test_SetSignerStatus_AddRemoveReAdd() public {
        mock.setSignerStatus(UNAUTHORIZED_SIGNER, true);
        assertTrue(mock.isAuthorizedSigner(UNAUTHORIZED_SIGNER));

        mock.setSignerStatus(UNAUTHORIZED_SIGNER, false);
        assertFalse(mock.isAuthorizedSigner(UNAUTHORIZED_SIGNER));

        mock.setSignerStatus(UNAUTHORIZED_SIGNER, true);
        assertTrue(mock.isAuthorizedSigner(UNAUTHORIZED_SIGNER));
    }

    /* ————————————————————————————————————————————————————————————————————————
                        HOOK IMPLEMENTATION TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify _getMaxPackageCount returns storage-backed value
     */
    function test_Hook_GetMaxPackageCount() public view {
        assertEq(mock.checkGetMaxPackageCount(), uint256(INIT_COUNT));
    }

    /*
     * Verify _getMaxPackageCount reflects updates
     */
    function test_Hook_GetMaxPackageCount_AfterUpdate() public {
        mock.setMaxPackageCount(50);
        assertEq(mock.checkGetMaxPackageCount(), 50);
    }

    /*
     * Verify _isAuthorizedSigner returns true for authorized signer
     */
    function test_Hook_IsAuthorizedSigner_Authorized() public view {
        assertTrue(mock.checkIsAuthorizedSigner(PRIMARY_SIGNER));
        assertTrue(mock.checkIsAuthorizedSigner(SECONDARY_SIGNER));
    }

    /*
     * Verify _isAuthorizedSigner returns false for unauthorized signer
     */
    function test_Hook_IsAuthorizedSigner_Unauthorized() public view {
        assertFalse(mock.checkIsAuthorizedSigner(UNAUTHORIZED_SIGNER));
    }

    /* ————————————————————————————————————————————————————————————————————————
                        TIMESTAMP VALIDATION TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify timestamp validation passes within allowed delay and drift
     */
    function test_ValidateTimestamp_Success() public {
        uint256 current = 10000;
        vm.warp(current);

        // Exact current time
        mock.validateTimestamp(TEST_FEED_ID, current);

        // At max allowed delay boundary
        mock.validateTimestamp(TEST_FEED_ID, current - INIT_DELAY);

        // At max allowed drift boundary
        mock.validateTimestamp(TEST_FEED_ID, current + INIT_DRIFT);
    }

    /*
     * Verify timestamp validation reverts when expired beyond maxDelay
     */
    function test_Revert_ValidateTimestamp_Expired() public {
        uint256 current = 10000;
        vm.warp(current);

        uint256 expiredTimestamp = current - uint256(INIT_DELAY) - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                TEST_FEED_ID,
                expiredTimestamp,
                current
            )
        );
        mock.validateTimestamp(TEST_FEED_ID, expiredTimestamp);
    }

    /*
     * Verify timestamp validation reverts when future drift exceeds maxFutureDrift
     */
    function test_Revert_ValidateTimestamp_FutureDrift() public {
        uint256 current = 10000;
        vm.warp(current);

        uint256 futureTimestamp = current + uint256(INIT_DRIFT) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                TEST_FEED_ID,
                futureTimestamp,
                current
            )
        );
        mock.validateTimestamp(TEST_FEED_ID, futureTimestamp);
    }

    /*
     * Verify timestamp validation uses updated config values
     */
    function test_ValidateTimestamp_AfterConfigUpdate() public {
        uint256 current = 10000;
        vm.warp(current);

        // With default INIT_DELAY=60, timestamp at current-61 should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                TEST_FEED_ID,
                current - 61,
                current
            )
        );
        mock.validateTimestamp(TEST_FEED_ID, current - 61);

        // Increase maxDelay to 120, now current-61 should pass
        mock.setMaxDelay(120);
        mock.validateTimestamp(TEST_FEED_ID, current - 61);
    }

    /*
     * Verify zero maxFutureDrift rejects any future timestamp
     */
    function test_Revert_ValidateTimestamp_ZeroDrift_RejectsFuture() public {
        mock.setMaxFutureDrift(0);

        uint256 current = 10000;
        vm.warp(current);

        // Current time should still pass
        mock.validateTimestamp(TEST_FEED_ID, current);

        // Any future timestamp should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                TEST_FEED_ID,
                current + 1,
                current
            )
        );
        mock.validateTimestamp(TEST_FEED_ID, current + 1);
    }

    /* ————————————————————————————————————————————————————————————————————————
                        SEQUENTIAL CONFIG MUTATION
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify chaining all three config updates produces correct final state
     */
    function test_SequentialConfigUpdate() public {
        uint8 newCount = 50;
        uint48 newDelay = 300;
        uint48 newDrift = 120;

        mock.setMaxPackageCount(newCount);
        mock.setMaxDelay(newDelay);
        mock.setMaxFutureDrift(newDrift);

        assertEq(mock.getMaxPackageCount(), uint256(newCount));
        assertEq(mock.getMaxDelay(), uint256(newDelay));
        assertEq(mock.getMaxFutureDrift(), uint256(newDrift));
    }

    /*
     * Fuzz: sequential config updates preserve all fields correctly
     */
    function test_SequentialConfigUpdate_Fuzz(uint8 newCount, uint48 newDelay, uint48 newDrift) public {
        vm.assume(newCount > 0 && newCount != INIT_COUNT);
        vm.assume(newDelay > 0 && newDelay != INIT_DELAY);
        vm.assume(newDrift != INIT_DRIFT);

        mock.setMaxPackageCount(newCount);
        mock.setMaxDelay(newDelay);
        mock.setMaxFutureDrift(newDrift);

        assertEq(mock.getMaxPackageCount(), uint256(newCount));
        assertEq(mock.getMaxDelay(), uint256(newDelay));
        assertEq(mock.getMaxFutureDrift(), uint256(newDrift));
    }

    /* ————————————————————————————————————————————————————————————————————————
                    INTEGRATION TESTS: FEED VERIFICATION WITH STORAGE CONFIG
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify successful feed data retrieval with storage-backed authorization
     */
    function test_Integration_ExecuteWithFeedData_Success() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        timestamps[0] = block.timestamp;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedData.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, TEST_PRICE);
        assertEq(ts, block.timestamp);
        assertEq(mock.lastBusinessData(), hex"deadbeef");
    }

    /*
     * Verify storage-backed signer authorization rejects unauthorized signers
     */
    function test_Integration_ExecuteWithFeedData_Revert_UnauthorizedSigner() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        timestamps[0] = block.timestamp;

        // Sign with unauthorized key
        bytes memory extraData = _buildSignedExtraData(UNAUTHORIZED_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedData.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );

        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnauthorizedSigner.selector, UNAUTHORIZED_SIGNER));
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify storage-backed maxDelay is enforced during feed verification
     */
    function test_Integration_ExecuteWithFeedData_Revert_Expired() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        // Exceed INIT_DELAY (60s)
        timestamps[0] = block.timestamp - uint256(INIT_DELAY) - 1;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedData.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                TEST_FEED_ID,
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify storage-backed maxFutureDrift is enforced during feed verification
     */
    function test_Integration_ExecuteWithFeedData_Revert_FutureDrift() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        // Exceed INIT_DRIFT (30s)
        timestamps[0] = block.timestamp + uint256(INIT_DRIFT) + 1;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedData.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                TEST_FEED_ID,
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify updating maxDelay affects feed verification
     */
    function test_Integration_ExecuteWithFeedData_ConfigUpdateTakesEffect_MaxDelay() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        // Exceeds default 60s but within extended 120s
        timestamps[0] = block.timestamp - uint256(INIT_DELAY) - 1;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedData.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert with default maxDelay=60
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                TEST_FEED_ID,
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(fullPayload);

        // Increase maxDelay to 120s
        mock.setMaxDelay(120);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, TEST_PRICE);
        assertEq(ts, timestamps[0]);
    }

    /*
     * Verify updating maxFutureDrift affects feed verification
     */
    function test_Integration_ExecuteWithFeedData_ConfigUpdateTakesEffect_MaxFutureDrift() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        // Exceeds default 30s but within extended 60s
        timestamps[0] = block.timestamp + uint256(INIT_DRIFT) + 1;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedData.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert with default maxFutureDrift=30
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                TEST_FEED_ID,
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(fullPayload);

        // Increase maxFutureDrift to 60s
        mock.setMaxFutureDrift(60);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, TEST_PRICE);
        assertEq(ts, timestamps[0]);
    }

    /*
     * Verify adding a new signer allows feed verification with that signer
     */
    function test_Integration_ExecuteWithFeedData_SignerUpdateTakesEffect_Add() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        timestamps[0] = block.timestamp;

        // Sign with UNAUTHORIZED_SIGNER_PK
        bytes memory extraData = _buildSignedExtraData(UNAUTHORIZED_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedData.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert - signer not authorized
        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnauthorizedSigner.selector, UNAUTHORIZED_SIGNER));
        address(mock).revertingCall(fullPayload);

        // Add the signer
        mock.setSignerStatus(UNAUTHORIZED_SIGNER, true);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256 price, ) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, TEST_PRICE);
    }

    /*
     * Verify removing a signer blocks feed verification with that signer
     */
    function test_Integration_ExecuteWithFeedData_SignerUpdateTakesEffect_Remove() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        timestamps[0] = block.timestamp;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedData.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should succeed initially
        (bool success, ) = address(mock).call(fullPayload);
        assertTrue(success);

        // Remove the signer
        mock.setSignerStatus(PRIMARY_SIGNER, false);

        // Now should revert
        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnauthorizedSigner.selector, PRIMARY_SIGNER));
        address(mock).revertingCall(fullPayload);
    }

    /*
     * Verify storage-backed maxPackageCount is enforced
     */
    function test_Integration_ExecuteWithFeedData_Revert_ExceedsMaxPackageCount() public {
        // Create more packages than INIT_COUNT (10)
        uint256 packageCount = uint256(INIT_COUNT) + 1;

        bytes4[] memory ids = new bytes4[](packageCount);
        uint256[] memory prices = new uint256[](packageCount);
        uint256[] memory timestamps = new uint256[](packageCount);

        for (uint256 i = 0; i < packageCount; ) {
            ids[i] = bytes4(keccak256(abi.encode("feed", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(mock.executeWithFeedData.selector, ids[0], hex"deadbeef");

        vm.expectRevert(
            abi.encodeWithSelector(IPullOracleBase.ExceedsMaxPackageCount.selector, packageCount, INIT_COUNT)
        );
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify updating maxPackageCount allows more packages
     */
    function test_Integration_ExecuteWithFeedData_ConfigUpdateTakesEffect_MaxPackageCount() public {
        // Create 11 packages - exceeds default 10 but within updated 20
        uint256 packageCount = uint256(INIT_COUNT) + 1;

        bytes4[] memory ids = new bytes4[](packageCount);
        uint256[] memory prices = new uint256[](packageCount);
        uint256[] memory timestamps = new uint256[](packageCount);

        for (uint256 i = 0; i < packageCount; ) {
            ids[i] = bytes4(keccak256(abi.encode("feed", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(mock.executeWithFeedData.selector, ids[0], hex"deadbeef");
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert with default maxPackageCount=10
        vm.expectRevert(
            abi.encodeWithSelector(IPullOracleBase.ExceedsMaxPackageCount.selector, packageCount, INIT_COUNT)
        );
        address(mock).revertingCall(fullPayload);

        // Increase maxPackageCount to 20
        mock.setMaxPackageCount(20);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256 price, ) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, prices[0]);
    }

    /* ————————————————————————————————————————————————————————————————————————
                    INTEGRATION TESTS: LENIENT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify lenient mode returns zero for unmatched feed ID instead of reverting
     */
    function test_Integration_ExecuteWithFeedDataLenient_Success_UnmatchedReturnsZero() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = bytes4(keccak256("other_feed"));
        prices[0] = TEST_PRICE;
        timestamps[0] = block.timestamp;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataLenient.selector,
            TEST_FEED_ID, // Not in payload
            hex"deadbeef"
        );

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, 0);
        assertEq(ts, 0);
        assertEq(mock.lastBusinessData(), hex"deadbeef");
    }

    /*
     * Verify lenient mode still reverts on expired timestamp when feed is matched
     */
    function test_Integration_ExecuteWithFeedDataLenient_Revert_Expired() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        timestamps[0] = block.timestamp - uint256(INIT_DELAY) - 1;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataLenient.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                TEST_FEED_ID,
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify lenient mode still reverts on future drift when feed is matched
     */
    function test_Integration_ExecuteWithFeedDataLenient_Revert_FutureDrift() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        timestamps[0] = block.timestamp + uint256(INIT_DRIFT) + 1;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataLenient.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                TEST_FEED_ID,
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify lenient mode config update takes effect for maxDelay
     */
    function test_Integration_ExecuteWithFeedDataLenient_ConfigUpdateTakesEffect_MaxDelay() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        timestamps[0] = block.timestamp - uint256(INIT_DELAY) - 1;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataLenient.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert with default maxDelay=60
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                TEST_FEED_ID,
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(fullPayload);

        // Increase maxDelay to 120s
        mock.setMaxDelay(120);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, TEST_PRICE);
        assertEq(ts, timestamps[0]);
    }

    /*
     * Verify lenient mode config update takes effect for maxFutureDrift
     */
    function test_Integration_ExecuteWithFeedDataLenient_ConfigUpdateTakesEffect_MaxFutureDrift() public {
        bytes4[] memory ids = new bytes4[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory timestamps = new uint256[](1);

        ids[0] = TEST_FEED_ID;
        prices[0] = TEST_PRICE;
        timestamps[0] = block.timestamp + uint256(INIT_DRIFT) + 1;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataLenient.selector,
            TEST_FEED_ID,
            hex"deadbeef"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert with default maxFutureDrift=30
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                TEST_FEED_ID,
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(fullPayload);

        // Increase maxFutureDrift to 60s
        mock.setMaxFutureDrift(60);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256 price, uint256 ts) = abi.decode(returnData, (uint256, uint256));
        assertEq(price, TEST_PRICE);
        assertEq(ts, timestamps[0]);
    }

    /* ————————————————————————————————————————————————————————————————————————
                    INTEGRATION TESTS: BATCH STRICT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify successful batch retrieval with storage-backed authorization
     */
    function test_Integration_ExecuteWithFeedDataBatch_Success() public {
        uint256 count = 3;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("feed", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp - i;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[2];
        requestedIds[1] = ids[0];

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatch.selector,
            requestedIds,
            hex"cafebabe"
        );

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices[0], prices[2]);
        assertEq(rPrices[1], prices[0]);
        assertEq(rTs[0], timestamps[2]);
        assertEq(rTs[1], timestamps[0]);
        assertEq(mock.lastBusinessData(), hex"cafebabe");
    }

    /*
     * Verify batch strict mode reverts when one feed ID is missing
     */
    function test_Integration_ExecuteWithFeedDataBatch_Revert_UnmatchedFeedID() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("feed", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp;
            unchecked {
                ++i;
            }
        }

        bytes4 missingId = 0xdeadbeef;
        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = missingId;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatch.selector,
            requestedIds,
            hex"cafebabe"
        );

        vm.expectRevert(abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, missingId));
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify batch strict mode reverts when one matched feed has expired timestamp
     */
    function test_Integration_ExecuteWithFeedDataBatch_Revert_PartialExpired() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        ids[0] = bytes4(keccak256("fresh"));
        prices[0] = 100e18;
        timestamps[0] = block.timestamp;

        ids[1] = bytes4(keccak256("stale"));
        prices[1] = 200e18;
        timestamps[1] = block.timestamp - uint256(INIT_DELAY) - 1;

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatch.selector,
            requestedIds,
            hex"cafebabe"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                ids[1],
                timestamps[1],
                block.timestamp
            )
        );
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify batch strict mode reverts when one matched feed exceeds future drift tolerance
     */
    function test_Integration_ExecuteWithFeedDataBatch_Revert_PartialFutureDrift() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        ids[0] = bytes4(keccak256("normal"));
        prices[0] = 100e18;
        timestamps[0] = block.timestamp;

        ids[1] = bytes4(keccak256("future"));
        prices[1] = 200e18;
        timestamps[1] = block.timestamp + uint256(INIT_DRIFT) + 1;

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatch.selector,
            requestedIds,
            hex"cafebabe"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                ids[1],
                timestamps[1],
                block.timestamp
            )
        );
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify batch strict mode config update takes effect for maxDelay
     */
    function test_Integration_ExecuteWithFeedDataBatch_ConfigUpdateTakesEffect_MaxDelay() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("feed", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp - uint256(INIT_DELAY) - 1;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatch.selector,
            requestedIds,
            hex"cafebabe"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert with default maxDelay=60
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                ids[0],
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(fullPayload);

        // Increase maxDelay to 120s
        mock.setMaxDelay(120);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256[] memory rPrices, ) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices[0], prices[0]);
        assertEq(rPrices[1], prices[1]);
    }

    /*
     * Verify batch strict mode config update takes effect for maxFutureDrift
     */
    function test_Integration_ExecuteWithFeedDataBatch_ConfigUpdateTakesEffect_MaxFutureDrift() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("feed", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp + uint256(INIT_DRIFT) + 1;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatch.selector,
            requestedIds,
            hex"cafebabe"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert with default maxFutureDrift=30
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                ids[0],
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(fullPayload);

        // Increase maxFutureDrift to 60s
        mock.setMaxFutureDrift(60);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256[] memory rPrices, ) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices[0], prices[0]);
        assertEq(rPrices[1], prices[1]);
    }

    /*
     * Verify empty feedIds array short-circuits before authentication and returns empty arrays
     */
    function test_Integration_ExecuteWithFeedDataBatch_Success_EmptyFeedIds() public {
        bytes4[] memory emptyIds = new bytes4[](0);

        // No extraData appended — authentication must not execute
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatch.selector,
            emptyIds,
            hex"cafebabe"
        );

        (bool success, bytes memory returnData) = address(mock).call(businessCall);
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices.length, 0);
        assertEq(rTs.length, 0);
        assertEq(mock.lastBusinessData(), hex"cafebabe");
    }

    /* ————————————————————————————————————————————————————————————————————————
                    INTEGRATION TESTS: BATCH LENIENT MODE
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Verify batch lenient mode returns zero for unmatched feeds
     */
    function test_Integration_ExecuteWithFeedDataBatchLenient_Success_PartialUnmatched() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        ids[0] = bytes4(keccak256("present"));
        prices[0] = 100e18;
        timestamps[0] = block.timestamp;

        ids[1] = bytes4(keccak256("other"));
        prices[1] = 200e18;
        timestamps[1] = block.timestamp;

        bytes4 missingId = 0xdeadbeef;
        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = missingId;

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatchLenient.selector,
            requestedIds,
            hex"cafebabe"
        );

        (bool success, bytes memory returnData) = address(mock).call(_attachExtraData(businessCall, extraData));
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices[0], prices[0]);
        assertEq(rTs[0], timestamps[0]);
        assertEq(rPrices[1], 0);
        assertEq(rTs[1], 0);
        assertEq(mock.lastBusinessData(), hex"cafebabe");
    }

    /*
     * Verify batch lenient mode still reverts on expired matched feed
     */
    function test_Integration_ExecuteWithFeedDataBatchLenient_Revert_PartialExpired() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        ids[0] = bytes4(keccak256("fresh"));
        prices[0] = 100e18;
        timestamps[0] = block.timestamp;

        ids[1] = bytes4(keccak256("stale"));
        prices[1] = 200e18;
        timestamps[1] = block.timestamp - uint256(INIT_DELAY) - 1;

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatchLenient.selector,
            requestedIds,
            hex"cafebabe"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                ids[1],
                timestamps[1],
                block.timestamp
            )
        );
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify batch lenient mode reverts when one matched feed exceeds future drift tolerance
     */
    function test_Integration_ExecuteWithFeedDataBatchLenient_Revert_PartialFutureDrift() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        ids[0] = bytes4(keccak256("normal"));
        prices[0] = 100e18;
        timestamps[0] = block.timestamp;

        ids[1] = bytes4(keccak256("future"));
        prices[1] = 200e18;
        timestamps[1] = block.timestamp + uint256(INIT_DRIFT) + 1;

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatchLenient.selector,
            requestedIds,
            hex"cafebabe"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                ids[1],
                timestamps[1],
                block.timestamp
            )
        );
        address(mock).revertingCall(_attachExtraData(businessCall, extraData));
    }

    /*
     * Verify batch lenient mode config update takes effect for maxDelay
     */
    function test_Integration_ExecuteWithFeedDataBatchLenient_ConfigUpdateTakesEffect_MaxDelay() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("feed", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp - uint256(INIT_DELAY) - 1;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatchLenient.selector,
            requestedIds,
            hex"cafebabe"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert with default maxDelay=60
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedExpired.selector,
                ids[0],
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(fullPayload);

        // Increase maxDelay to 120s
        mock.setMaxDelay(120);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256[] memory rPrices, ) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices[0], prices[0]);
        assertEq(rPrices[1], prices[1]);
    }

    /*
     * Verify batch lenient mode config update takes effect for maxFutureDrift
     */
    function test_Integration_ExecuteWithFeedDataBatchLenient_ConfigUpdateTakesEffect_MaxFutureDrift() public {
        uint256 count = 2;

        bytes4[] memory ids = new bytes4[](count);
        uint256[] memory prices = new uint256[](count);
        uint256[] memory timestamps = new uint256[](count);

        for (uint256 i = 0; i < count; ) {
            ids[i] = bytes4(keccak256(abi.encode("feed", i)));
            prices[i] = (i + 1) * 100e18;
            timestamps[i] = block.timestamp + uint256(INIT_DRIFT) + 1;
            unchecked {
                ++i;
            }
        }

        bytes4[] memory requestedIds = new bytes4[](2);
        requestedIds[0] = ids[0];
        requestedIds[1] = ids[1];

        bytes memory extraData = _buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatchLenient.selector,
            requestedIds,
            hex"cafebabe"
        );
        bytes memory fullPayload = _attachExtraData(businessCall, extraData);

        // Should revert with default maxFutureDrift=30
        vm.expectRevert(
            abi.encodeWithSelector(
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector,
                ids[0],
                timestamps[0],
                block.timestamp
            )
        );
        address(mock).revertingCall(fullPayload);

        // Increase maxFutureDrift to 60s
        mock.setMaxFutureDrift(60);

        // Now should succeed
        (bool success, bytes memory returnData) = address(mock).call(fullPayload);
        assertTrue(success);

        (uint256[] memory rPrices, ) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices[0], prices[0]);
        assertEq(rPrices[1], prices[1]);
    }

    /*
     * Verify empty feedIds array short-circuits before authentication and returns empty arrays
     */
    function test_Integration_ExecuteWithFeedDataBatchLenient_Success_EmptyFeedIds() public {
        bytes4[] memory emptyIds = new bytes4[](0);

        // No extraData appended — authentication must not execute
        bytes memory businessCall = abi.encodeWithSelector(
            mock.executeWithFeedDataBatchLenient.selector,
            emptyIds,
            hex"cafebabe"
        );

        (bool success, bytes memory returnData) = address(mock).call(businessCall);
        assertTrue(success);

        (uint256[] memory rPrices, uint256[] memory rTs) = abi.decode(returnData, (uint256[], uint256[]));
        assertEq(rPrices.length, 0);
        assertEq(rTs.length, 0);
        assertEq(mock.lastBusinessData(), hex"cafebabe");
    }
}
