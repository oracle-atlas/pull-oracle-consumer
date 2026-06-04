// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {PullOracleConsumerBase} from "src/base/PullOracleConsumerBase.sol";
import {PullOracleReferenceHooks} from "src/libraries/PullOracleReferenceHooks.sol";

/*
 * Full-exposure mock for PullOracleConsumerBase using default reference hooks
 */
contract PullOracleConsumerBaseMock is PullOracleConsumerBase {
    /*
     * Expose internal verified feed data retrieval in strict mode
     */
    function getVerifiedFeedData(bytes4 feedId) external view returns (uint256 price, uint256 aggregatedTimestamp) {
        return _getVerifiedFeedData(feedId);
    }

    /*
     * Expose internal verified feed data batch retrieval in strict mode
     */
    function getVerifiedFeedDataBatch(
        bytes4[] calldata feedIds
    ) external view returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        return _getVerifiedFeedDataBatch(feedIds);
    }

    /*
     * Expose internal verified feed data retrieval in lenient mode
     */
    function getVerifiedFeedDataLenient(
        bytes4 feedId
    ) external view returns (uint256 price, uint256 aggregatedTimestamp) {
        return _getVerifiedFeedDataLenient(feedId);
    }

    /*
     * Expose internal verified feed data batch retrieval in lenient mode
     */
    function getVerifiedFeedDataBatchLenient(
        bytes4[] calldata feedIds
    ) external view returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        return _getVerifiedFeedDataBatchLenient(feedIds);
    }

    /*
     * Expose internal search engine for single ID in strict mode
     */
    function getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched(
        bytes4 feedId,
        uint256 payloadStart,
        uint256 payloadEnd
    ) external view returns (uint256 price, uint256 aggregatedTimestamp) {
        return _getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched(feedId, payloadStart, payloadEnd);
    }

    /*
     * Expose internal search engine for batch IDs in strict mode
     */
    function getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched(
        bytes4[] calldata feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) external view returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        return _getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched(feedIds, payloadStart, payloadEnd);
    }

    /*
     * Expose internal search engine for single ID in lenient mode
     */
    function getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched(
        bytes4 feedId,
        uint256 payloadStart,
        uint256 payloadEnd
    ) external view returns (uint256 price, uint256 aggregatedTimestamp) {
        return _getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched(feedId, payloadStart, payloadEnd);
    }

    /*
     * Expose internal search engine for batch IDs in lenient mode
     */
    function getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched(
        bytes4[] calldata feedIds,
        uint256 payloadStart,
        uint256 payloadEnd
    ) external view returns (uint256[] memory prices, uint256[] memory aggregatedTimestamps) {
        return _getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched(feedIds, payloadStart, payloadEnd);
    }

    /*
     * Expose internal authentication and metadata unpacking logic
     */
    function authenticateAndUnpackExtraData() external view returns (uint256 payloadStart, uint256 payloadEnd) {
        return _authenticateAndUnpackExtraData();
    }

    /* ————————————————————————————————————————————————————————————————————————
                                DEFAULT HOOK IMPLEMENTATIONS
    ————————————————————————————————————————————————————————————————————————— */

    /*
     * Implementation of timestamp validation using default protocol-wide constants
     */
    function _validateTimestamp(bytes4 feedId, uint256 parsedAggregateTimestamp) internal view override {
        PullOracleReferenceHooks.validateTimestamp(feedId, parsedAggregateTimestamp);
    }

    /*
     * Implementation of package limit using default protocol-wide constants
     */
    function _getMaxPackageCount() internal pure override returns (uint256) {
        return PullOracleReferenceHooks.DEFAULT_MAX_PACKAGE_COUNT;
    }

    /*
     * Implementation of authorization check using hardcoded test signer addresses
     * Test signers: 0x532FAFF264Be605F7cca78Db5662fdCBE689FC5d (primary)
     *               0xf41C5b73ac6EfCFA6c6E71eF64aE3F0815f0CF49 (secondary)
     */
    function _isAuthorizedSigner(address recoveredSigner) internal pure override returns (bool) {
        return (recoveredSigner == 0x532FAFF264Be605F7cca78Db5662fdCBE689FC5d ||
            recoveredSigner == 0xf41C5b73ac6EfCFA6c6E71eF64aE3F0815f0CF49);
    }
}
