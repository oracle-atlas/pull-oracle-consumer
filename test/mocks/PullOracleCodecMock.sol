// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {PullOracleCodec} from "src/libraries/PullOracleCodec.sol";

/**
 * Provide external access to internal library functions for unit testing.
 */
contract PullOracleCodecMock {
    /*
     * Expose internal metadata parsing logic to external testing environment
     */
    function parseMetadata(uint256 maxPackageCount) external pure returns (uint256 payloadStart, uint256 payloadEnd) {
        return PullOracleCodec._parseMetadata(maxPackageCount);
    }

    /*
     * Parse protocol metadata in standard context with no extra business arguments
     */
    function parseMetadataWithoutBusinessCalldata() external pure returns (uint256 payloadStart, uint256 payloadEnd) {
        return PullOracleCodec._parseMetadata(type(uint8).max);
    }

    /*
     * Expose feed package decoding for word-by-word integrity validation
     */
    function parseFeedPackage(bytes32 word) external pure returns (uint256 price, uint256 timestamp) {
        return PullOracleCodec._parseFeedPackage(word);
    }
}
