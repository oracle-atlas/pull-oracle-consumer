// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24; // Minimum 0.8.24 required for Cancun opcodes

import {PullOracleConsumerTransientStorage} from "src-advanced/PullOracleConsumerTransientStorage.sol";

/**
 * Tron-side test harness for PullOracleConsumerTransientStorage.
 *
 * Deliberately separate from PullOracleConsumerTransientStorageMock:
 *   1. TVM rejects contract names > 32 bytes on deploy, and the shared mock's
 *      name (38 chars) exceeds the limit — this harness stays under it.
 *   2. Tron transaction receipts carry no return data, so the write-path
 *      results (price / timestamp) are recorded here and asserted through
 *      the public getters.
 *
 * Surface mirrors the shared mock: same setters, hooks and execute* business
 * functions (strict/lenient, batch and transient-batch), delegating entirely
 * to the inherited PullOracleConsumerTransientStorage.
 */
contract ConsumerTransientStorageTvmMock is PullOracleConsumerTransientStorage {
    // Arrays are private on purpose: Solidity's auto-getter for public arrays
    // only exposes element access, so whole-array reads need named functions.
    // Scalars/bytes can be public — their auto-getters return the whole value.
    bytes public lastBusinessData;
    uint256 public lastPrice;
    uint256 public lastTimestamp;
    uint256[] private _lastPrices;
    uint256[] private _lastTimestamps;

    function lastPrices() external view returns (uint256[] memory) {
        return _lastPrices;
    }

    function lastTimestamps() external view returns (uint256[] memory) {
        return _lastTimestamps;
    }

    constructor(
        uint8 maxPackageCount,
        uint48 maxDelay,
        uint48 maxFutureDrift,
        address[] memory initialSigners
    ) PullOracleConsumerTransientStorage(maxPackageCount, maxDelay, maxFutureDrift, initialSigners) {}

    function setMaxPackageCount(uint8 newMaxPackageCount) external {
        _setMaxPackageCount(newMaxPackageCount);
    }

    function setMaxDelay(uint48 newMaxDelay) external {
        _setMaxDelay(newMaxDelay);
    }

    function setMaxFutureDrift(uint48 newMaxFutureDrift) external {
        _setMaxFutureDrift(newMaxFutureDrift);
    }

    function setSignerStatus(address signer, bool status) external {
        _setSignerStatus(signer, status);
    }

    function validateTimestamp(bytes4 feedId, uint256 parsedAggregateTimestamp) external view {
        _validateTimestamp(feedId, parsedAggregateTimestamp);
    }

    function checkIsAuthorizedSigner(address recoveredSigner) external view returns (bool) {
        return _isAuthorizedSigner(recoveredSigner);
    }

    function checkGetMaxPackageCount() external view returns (uint256) {
        return _getMaxPackageCount();
    }

    function executeWithFeedData(bytes4 feedId, bytes calldata businessData) external {
        lastBusinessData = businessData;
        (lastPrice, lastTimestamp) = _getVerifiedFeedData(feedId);
    }

    function executeWithFeedDataLenient(bytes4 feedId, bytes calldata businessData) external {
        lastBusinessData = businessData;
        (lastPrice, lastTimestamp) = _getVerifiedFeedDataLenient(feedId);
    }

    function executeWithFeedDataBatch(bytes4[] calldata feedIds, bytes calldata businessData) external {
        lastBusinessData = businessData;
        (_lastPrices, _lastTimestamps) = _getVerifiedFeedDataBatch(feedIds);
    }

    function executeWithFeedDataBatchLenient(bytes4[] calldata feedIds, bytes calldata businessData) external {
        lastBusinessData = businessData;
        (_lastPrices, _lastTimestamps) = _getVerifiedFeedDataBatchLenient(feedIds);
    }

    // Transient batch paths (EIP-1153 optimized, O(M+N) lookup).
    function executeWithFeedDataBatchTransient(bytes4[] calldata feedIds, bytes calldata businessData) external {
        lastBusinessData = businessData;
        (_lastPrices, _lastTimestamps) = _getVerifiedFeedDataBatchTransient(feedIds);
    }

    function executeWithFeedDataBatchLenientTransient(bytes4[] calldata feedIds, bytes calldata businessData) external {
        lastBusinessData = businessData;
        (_lastPrices, _lastTimestamps) = _getVerifiedFeedDataBatchLenientTransient(feedIds);
    }
}
