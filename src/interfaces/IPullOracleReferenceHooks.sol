// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/**
 * @title IPullOracleReferenceHooks
 * @notice Define specific error signatures for the PullOracleReferenceHooks reference library
 * @dev Centralize validation errors to ensure consistent revert data. This allows external integrators to decode errors predictably.
 */
interface IPullOracleReferenceHooks {
    /**
     * @notice Throw when the price timestamp exceeds the maximum allowed freshness threshold
     * @param feedId The 4-byte identifier for the specific asset
     * @param timestamp The parsed off-chain timestamp
     * @param current The current on-chain block timestamp
     */
    error PriceFeedExpired(bytes4 feedId, uint256 timestamp, uint256 current);

    /**
     * @notice Throw when the price timestamp leads the block timestamp beyond the allowed drift limit
     * @param feedId The 4-byte identifier for the specific asset
     * @param timestamp The parsed off-chain timestamp
     * @param current The current on-chain block timestamp
     */
    error PriceFeedFutureDrift(bytes4 feedId, uint256 timestamp, uint256 current);
}
