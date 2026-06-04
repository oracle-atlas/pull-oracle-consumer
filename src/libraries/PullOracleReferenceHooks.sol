// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {IPullOracleReferenceHooks} from "interfaces/IPullOracleReferenceHooks.sol";
import {CustomErrorRevert} from "libraries/CustomErrorRevert.sol";

/**
 * @title PullOracleReferenceHooks
 * @notice Reference implementations for PullOracleConsumerBase internal hooks
 * @dev These implementations provide reference values for the Atlas Oracle integration.
 * Integrators MUST review the following trust assumptions before relying on these defaults:
 *
 *   - Authorized signer: 0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600 (Atlas Oracle official signing key)
 *   - Max delay: 180 seconds (price data older than this is rejected as stale)
 *   - Max future drift: 60 seconds (tolerance for clock skew between signer and validator)
 *   - Max package count: 255 (uint8 upper bound, limits per-call feed count)
 *
 * If any of these assumptions do not match your protocol's security requirements, override the
 * corresponding hook(s) in your consumer subclass. Alternatively, inherit from the Storage
 * variant (PullOracleConsumerStandardStorage / PullOracleConsumerTransientStorage) for runtime
 * configurability via governance-controlled setters.
 *
 * @dev This library is gas-efficient by design: all parameters are compile-time constants,
 * eliminating SLOAD overhead. It utilizes assembly reverts through CustomErrorRevert.
 */
library PullOracleReferenceHooks {
    using CustomErrorRevert for bytes4;

    // Define the default maximum package count using the uint8 upper bound
    uint256 internal constant DEFAULT_MAX_PACKAGE_COUNT = type(uint8).max;

    // Define the default maximum allowed age for a price package in seconds (180s)
    uint256 internal constant DEFAULT_MAX_DELAY = 180;

    // Define the default maximum allowed clock drift for future timestamps in seconds (60s)
    uint256 internal constant DEFAULT_MAX_FUTURE_DRIFT = 60;

    /* ————————————————————————————————————————————————————————————————————————
                              REFERENCE IMPLEMENTATIONS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Execute price freshness validation using hardcoded default constants.
     * @param feedId The 4-byte identifier for the specific asset
     * @param parsedTimestamp The 48-bit timestamp extracted from the feed package
     */
    function validateTimestamp(bytes4 feedId, uint256 parsedTimestamp) internal view {
        unchecked {
            if (block.timestamp >= parsedTimestamp) {
                // Revert when timestamp lag exceeds max delay
                if (block.timestamp - parsedTimestamp > DEFAULT_MAX_DELAY) {
                    IPullOracleReferenceHooks.PriceFeedExpired.selector.revertWithFeedIdAndDualTimestamps(
                        feedId,
                        parsedTimestamp,
                        block.timestamp
                    );
                }
            } else if (parsedTimestamp - block.timestamp > DEFAULT_MAX_FUTURE_DRIFT) {
                // Revert when timestamp drift exceeds max future tolerance
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector.revertWithFeedIdAndDualTimestamps(
                    feedId,
                    parsedTimestamp,
                    block.timestamp
                );
            }
        }
    }

    /**
     * @dev Execute authorization lookup for the recovered signer against the hardcoded
     * production address. Override _isAuthorizedSigner in your consumer subclass to
     * substitute a different signer or use a storage-based registry.
     * @param recoveredSigner the address recovered from the signature
     * @return true if the recovered address matches an authorized signer
     */
    function isAuthorizedSigner(address recoveredSigner) internal pure returns (bool) {
        // Execute direct comparison against hardcoded authorized signers
        return recoveredSigner == 0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600;
    }
}
