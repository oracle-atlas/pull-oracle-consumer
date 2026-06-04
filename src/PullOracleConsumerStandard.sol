// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {PullOracleConsumerBase} from "base/PullOracleConsumerBase.sol";
import {PullOracleReferenceHooks} from "libraries/PullOracleReferenceHooks.sol";

/**
 * @title PullOracleConsumerStandard
 * @notice Standard consumer with reference hook implementations from PullOracleReferenceHooks
 * @dev This contract bridges the base consumer with gas-optimized default hooks. All hook
 *      parameters (authorized signer, timestamp boundaries, max package count) are hardcoded
 *      constants, yielding the lowest possible gas consumption.
 *
 * IMPORTANT: Integrators MUST review the trust assumptions documented in PullOracleReferenceHooks
 * before deploying. The hardcoded values serve as reference defaults for the Atlas Oracle integration
 * and may not be appropriate for all deployment scenarios. If your protocol requires tighter
 * freshness bounds or custom package limits, override the corresponding hook(s) in your
 * subclass. Alternatively, inherit from PullOracleConsumerStandardStorage for runtime
 * configurability via storage-backed setters.
 *
 * The official production signing address is hardcoded in PullOracleReferenceHooks.isAuthorizedSigner.
 *
 * The tradeoff is immutability — modifying any of these values post-deployment requires a
 * contract upgrade. If runtime configurability is preferred over gas optimization, inherit
 * from PullOracleConsumerStandardStorage instead, which provides a storage-backed registry
 * with governance-controlled signer rotation, adjustable timestamp thresholds, and dynamic
 * package count limits.
 */
abstract contract PullOracleConsumerStandard is PullOracleConsumerBase {
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
