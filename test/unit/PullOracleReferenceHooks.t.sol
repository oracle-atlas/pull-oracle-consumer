// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {BaseTest} from "test/utils/BaseTest.t.sol";
import {PullOracleReferenceHooksMock} from "test/mocks/PullOracleReferenceHooksMock.sol";
import {IPullOracleReferenceHooks} from "interfaces/IPullOracleReferenceHooks.sol";

/*
 * Verify stateless hook logic for freshness and authorization compliance
 */
contract PullOracleReferenceHooksTest is BaseTest {
    PullOracleReferenceHooksMock internal mock = new PullOracleReferenceHooksMock();
    bytes4 internal constant TEST_FEED_ID = 0x01020304;

    /*
     * Validate successful timestamp check within allowed delay and drift windows
     */
    function test_ValidateTimestamp_Success() public {
        uint256 current = 1000;
        vm.warp(current);

        // Execute validation with timestamp exactly at current time
        mock.validateTimestamp(TEST_FEED_ID, current);

        // Execute validation with timestamp at max allowed delay (180s)
        mock.validateTimestamp(TEST_FEED_ID, current - 180);

        // Execute validation with timestamp at max allowed drift (60s)
        mock.validateTimestamp(TEST_FEED_ID, current + 60);
    }

    /*
     * Verify revert when price package timestamp is older than max delay
     */
    function test_Revert_PriceFeedExpired() public {
        uint256 current = 1000;
        vm.warp(current);

        // Define expired timestamp (delay = 181s > 180s)
        uint256 expiredTimestamp = current - 181;

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
     * Verify revert when price package timestamp drifts too far into the future
     */
    function test_Revert_PriceFeedFutureDrift() public {
        uint256 current = 1000;
        vm.warp(current);

        // Define drifting timestamp (drift = 61s > 60s)
        uint256 futureTimestamp = current + 61;

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
     * Verify that hardcoded authorized signer returns true
     */
    function test_IsAuthorizedSigner_Success() public view {
        assertTrue(mock.isAuthorizedSigner(0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600));
    }

    /*
     * Ensure unauthorized addresses return false
     */
    function test_IsAuthorizedSigner_Unauthorized_ReturnsFalse() public view {
        assertFalse(mock.isAuthorizedSigner(address(0xdead)));
    }
}
