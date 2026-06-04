// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24; // Minimum 0.8.24 required for Cancun opcodes

import {PullOracleConsumerTransientStorage} from "src-advanced/PullOracleConsumerTransientStorage.sol";

// Concrete harness exposing internal setters and hooks for unit testing
contract PullOracleConsumerTransientStorageMock is PullOracleConsumerTransientStorage {
    // Storage slot to simulate real business logic writes
    bytes public lastBusinessData;

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

    /* ————————————————————————————————————————————————————————————————————————
                            BASE API (view, inherited from Base)
    ————————————————————————————————————————————————————————————————————————— */

    // Simulate real business function: verify feed, write to storage, return price data
    function executeWithFeedData(
        bytes4 feedId,
        bytes calldata businessData
    ) external returns (uint256 price, uint256 aggregatedTimestamp) {
        lastBusinessData = businessData;
        return _getVerifiedFeedData(feedId);
    }

    // Simulate real business function in lenient mode
    function executeWithFeedDataLenient(
        bytes4 feedId,
        bytes calldata businessData
    ) external returns (uint256 price, uint256 aggregatedTimestamp) {
        lastBusinessData = businessData;
        return _getVerifiedFeedDataLenient(feedId);
    }

    // Simulate real batch business function: verify multiple feeds, write to storage
    function executeWithFeedDataBatch(
        bytes4[] calldata feedIds,
        bytes calldata businessData
    ) external returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        lastBusinessData = businessData;
        return _getVerifiedFeedDataBatch(feedIds);
    }

    // Simulate real batch business function in lenient mode
    function executeWithFeedDataBatchLenient(
        bytes4[] calldata feedIds,
        bytes calldata businessData
    ) external returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        lastBusinessData = businessData;
        return _getVerifiedFeedDataBatchLenient(feedIds);
    }

    /* ————————————————————————————————————————————————————————————————————————
                        TRANSIENT API (non-view, EIP-1153 optimized)
    ————————————————————————————————————————————————————————————————————————— */

    // Simulate transient batch business function: strict mode with O(M+N) lookup
    function executeWithFeedDataBatchTransient(
        bytes4[] calldata feedIds,
        bytes calldata businessData
    ) external returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        lastBusinessData = businessData;
        return _getVerifiedFeedDataBatchTransient(feedIds);
    }

    // Simulate transient batch business function: lenient mode with O(M+N) lookup
    function executeWithFeedDataBatchLenientTransient(
        bytes4[] calldata feedIds,
        bytes calldata businessData
    ) external returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        lastBusinessData = businessData;
        return _getVerifiedFeedDataBatchLenientTransient(feedIds);
    }
}
