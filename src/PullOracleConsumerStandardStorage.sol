// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {IPullOracleConsumerStorage} from "interfaces/IPullOracleConsumerStorage.sol";
import {IPullOracleReferenceHooks} from "interfaces/IPullOracleReferenceHooks.sol";
import {PullOracleConfigCodec, PackedConfig} from "libraries/PullOracleConfigCodec.sol";
import {CustomErrorRevert} from "libraries/CustomErrorRevert.sol";
import {PullOracleConsumerBase} from "base/PullOracleConsumerBase.sol";

/**
 * @title PullOracleConsumerStandardStorage
 * @notice Storage-backed configurable base for Pull Oracle consumers
 * @dev Replace hardcoded constants and signer addresses in PullOracleReferenceHooks with
 *      mutable storage, enabling runtime governance over maxPackageCount, maxDelay,
 *      maxFutureDrift, and the authorized signer set.
 *
 *      Storage Layout:
 *        - _config (PackedConfig): Three fields packed into a single bytes32 slot via
 *          PullOracleConfigCodec. The _getMaxPackageCount() hook warms this slot during
 *          _parseMetadata, so _validateTimestamp()'s subsequent SLOAD is a warm hit
 *          (100 gas vs 2100 cold).
 *        - _authorizedSigners (mapping): O(1) signer lookup via SLOAD.
 *
 *      Type Strategy (write narrow, read wide):
 *        - Setters use narrow types (uint8, uint48) for compile-time overflow protection.
 *        - Getters and hooks return uint256 for EVM-native compatibility, avoiding extra
 *          masking opcodes and eliminating caller-side type conversions.
 *
 *      Inheritors MUST call the constructor with valid initial values. This contract does
 *      NOT expose public setters — subclasses should gate them behind access control
 *      (e.g., Ownable, AccessControl) and call the internal _set* functions.
 */
abstract contract PullOracleConsumerStandardStorage is PullOracleConsumerBase, IPullOracleConsumerStorage {
    using PullOracleConfigCodec for PackedConfig;
    using CustomErrorRevert for bytes4;

    /* ————————————————————————————————————————————————————————————————————————
                                    STORAGE
    ————————————————————————————————————————————————————————————————————————— */

    // Packed config slot: [8b maxPackageCount][48b maxDelay][48b maxFutureDrift]
    PackedConfig internal _config;

    // O(1) signer authorization lookup
    mapping(address => bool) internal _authorizedSigners;

    /* ————————————————————————————————————————————————————————————————————————
                                  CONSTRUCTOR
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Initialize the packed config slot and seed the authorized signer set.
     *      An empty initialSigners array is intentionally permitted to support two-step
     *      deployment flows where signers are added via governance after deployment.
     *      If initialSigners is empty, the inheritor MUST expose _setSignerStatus through
     *      an access-controlled public setter; otherwise the contract will be permanently
     *      unable to verify any oracle payload.
     * @param maxPackageCount Package count ceiling (must be non-zero)
     * @param maxDelay Staleness tolerance in seconds (must be non-zero)
     * @param maxFutureDrift Future drift tolerance in seconds (zero is a valid strict policy)
     * @param initialSigners Initial set of authorized signer addresses (empty array is valid)
     */
    constructor(uint8 maxPackageCount, uint48 maxDelay, uint48 maxFutureDrift, address[] memory initialSigners) {
        // Validate mandatory non-zero constraints
        if (maxPackageCount == 0) InvalidMaxPackageCount.selector.revertWith();
        if (maxDelay == 0) InvalidMaxDelay.selector.revertWith();

        _config = PullOracleConfigCodec._packConfig(maxPackageCount, maxDelay, maxFutureDrift);

        // Seed the authorized signer set
        uint256 signerCount = initialSigners.length;
        for (uint256 i = 0; i < signerCount; ) {
            _setSignerStatus(initialSigners[i], true);

            unchecked {
                ++i;
            }
        }
    }

    /* ————————————————————————————————————————————————————————————————————————
                            HOOK IMPLEMENTATIONS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Return the storage-backed package count ceiling.
     *      This SLOAD warms the _config slot for the subsequent _validateTimestamp call.
     */
    function _getMaxPackageCount() internal view virtual override returns (uint256) {
        return _config._extractMaxPackageCount();
    }

    /**
     * @dev Validate timestamp freshness and drift using storage-backed thresholds.
     *      The _config slot is already warm from _getMaxPackageCount(), so this
     *      SLOAD costs 100 gas instead of 2100.
     * @param feedId The 4-byte identifier for the specific asset
     * @param parsedAggregateTimestamp The 48-bit timestamp extracted from the feed package
     */
    function _validateTimestamp(bytes4 feedId, uint256 parsedAggregateTimestamp) internal view virtual override {
        (uint256 maxDelay, uint256 maxFutureDrift) = _config._extractTimestampThresholds();

        unchecked {
            if (block.timestamp >= parsedAggregateTimestamp) {
                // Revert when timestamp lag exceeds max delay
                if (block.timestamp - parsedAggregateTimestamp > maxDelay) {
                    IPullOracleReferenceHooks.PriceFeedExpired.selector.revertWithFeedIdAndDualTimestamps(
                        feedId,
                        parsedAggregateTimestamp,
                        block.timestamp
                    );
                }
            } else if (parsedAggregateTimestamp - block.timestamp > maxFutureDrift) {
                // Revert when timestamp drift exceeds max future tolerance
                IPullOracleReferenceHooks.PriceFeedFutureDrift.selector.revertWithFeedIdAndDualTimestamps(
                    feedId,
                    parsedAggregateTimestamp,
                    block.timestamp
                );
            }
        }
    }

    /**
     * @dev Authorize the recovered signer via storage mapping lookup.
     * @param recoveredSigner The address recovered from the cryptographic signature
     * @return true if the recovered address is in the authorized set
     */
    function _isAuthorizedSigner(address recoveredSigner) internal view virtual override returns (bool) {
        return _authorizedSigners[recoveredSigner];
    }

    /* ————————————————————————————————————————————————————————————————————————
                            INTERNAL SETTERS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Update the maxPackageCount field in the packed config slot.
     *      Reverts if the new value equals the current value.
     * @param newMaxPackageCount Replacement value (must be non-zero)
     */
    function _setMaxPackageCount(uint8 newMaxPackageCount) internal virtual {
        if (newMaxPackageCount == 0) InvalidMaxPackageCount.selector.revertWith();

        (PackedConfig newConfig, uint256 oldValue) = _config._updateMaxPackageCount(newMaxPackageCount);
        if (oldValue == newMaxPackageCount) ConfigValueAlreadySet.selector.revertWith();
        _config = newConfig;

        emit MaxPackageCountUpdated(oldValue, newMaxPackageCount);
    }

    /**
     * @dev Update the maxDelay field in the packed config slot.
     *      Reverts if the new value equals the current value.
     * @param newMaxDelay Replacement value in seconds (must be non-zero)
     */
    function _setMaxDelay(uint48 newMaxDelay) internal virtual {
        if (newMaxDelay == 0) InvalidMaxDelay.selector.revertWith();

        (PackedConfig newConfig, uint256 oldValue) = _config._updateMaxDelay(newMaxDelay);
        if (oldValue == newMaxDelay) ConfigValueAlreadySet.selector.revertWith();
        _config = newConfig;

        emit MaxDelayUpdated(oldValue, newMaxDelay);
    }

    /**
     * @dev Update the maxFutureDrift field in the packed config slot.
     *      Reverts if the new value equals the current value.
     * @param newMaxFutureDrift Replacement value in seconds (zero is a valid strict policy)
     */
    function _setMaxFutureDrift(uint48 newMaxFutureDrift) internal virtual {
        (PackedConfig newConfig, uint256 oldValue) = _config._updateMaxFutureDrift(newMaxFutureDrift);
        if (oldValue == newMaxFutureDrift) ConfigValueAlreadySet.selector.revertWith();
        _config = newConfig;

        emit MaxFutureDriftUpdated(oldValue, newMaxFutureDrift);
    }

    /**
     * @dev Update a signer's authorization status.
     * @param signer The address to authorize or deauthorize
     * @param status True to add, false to remove
     */
    function _setSignerStatus(address signer, bool status) internal virtual {
        if (signer == address(0)) ZeroAddressSigner.selector.revertWith();
        if (_authorizedSigners[signer] == status) SignerStatusAlreadySet.selector.revertWith(signer);

        _authorizedSigners[signer] = status;

        emit SignerStatusUpdated(signer, status);
    }

    /* ————————————————————————————————————————————————————————————————————————
                            EXTERNAL VIEW GETTERS
    ————————————————————————————————————————————————————————————————————————— */

    /// @inheritdoc IPullOracleConsumerStorage
    function getMaxPackageCount() external view returns (uint256) {
        return _getMaxPackageCount();
    }

    /// @inheritdoc IPullOracleConsumerStorage
    function getMaxDelay() external view returns (uint256) {
        return _config._extractMaxDelay();
    }

    /// @inheritdoc IPullOracleConsumerStorage
    function getMaxFutureDrift() external view returns (uint256) {
        return _config._extractMaxFutureDrift();
    }

    /// @inheritdoc IPullOracleConsumerStorage
    function isAuthorizedSigner(address signer) external view returns (bool) {
        return _authorizedSigners[signer];
    }
}
