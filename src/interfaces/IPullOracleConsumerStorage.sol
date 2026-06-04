// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/**
 * @title IPullOracleConsumerStorage
 * @notice Interface for storage-backed Pull Oracle consumers with mutable configuration
 * @dev Declare errors, events, and read-only accessors shared by all storage-backed
 *      implementations (standard storage, transient storage, etc.). Centralizing these
 *      declarations ensures consistent ABI encoding and enables type-safe external calls
 *      regardless of the underlying storage strategy.
 */
interface IPullOracleConsumerStorage {
    /* ————————————————————————————————————————————————————————————————————————
                                    ERRORS
    ————————————————————————————————————————————————————————————————————————— */

    // Thrown when maxPackageCount is set to zero
    error InvalidMaxPackageCount();

    // Thrown when maxDelay is set to zero
    error InvalidMaxDelay();

    // Thrown when setting a config field to its current value
    error ConfigValueAlreadySet();

    // Thrown when setting a signer to its current authorization status
    error SignerStatusAlreadySet(address signer);

    // Thrown when signer address is the zero address
    error ZeroAddressSigner();

    /* ————————————————————————————————————————————————————————————————————————
                                    EVENTS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Emitted when maxPackageCount is updated
     * @param oldValue The previous maxPackageCount
     * @param newValue The new maxPackageCount
     */
    event MaxPackageCountUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when maxDelay is updated
     * @param oldValue The previous maxDelay in seconds
     * @param newValue The new maxDelay in seconds
     */
    event MaxDelayUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when maxFutureDrift is updated
     * @param oldValue The previous maxFutureDrift in seconds
     * @param newValue The new maxFutureDrift in seconds
     */
    event MaxFutureDriftUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when a signer's authorization status changes
     * @param signer The address whose status changed
     * @param authorized True if added, false if removed
     */
    event SignerStatusUpdated(address indexed signer, bool authorized);

    /* ————————————————————————————————————————————————————————————————————————
                                EXTERNAL VIEW
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @notice Return the current maxPackageCount
     * @return The maximum number of packages allowed in a single update
     */
    function getMaxPackageCount() external view returns (uint256);

    /**
     * @notice Return the current maxDelay in seconds
     * @return The staleness tolerance threshold in seconds
     */
    function getMaxDelay() external view returns (uint256);

    /**
     * @notice Return the current maxFutureDrift in seconds
     * @return The future drift tolerance threshold in seconds
     */
    function getMaxFutureDrift() external view returns (uint256);

    /**
     * @notice Check whether an address is an authorized signer
     * @param signer The address to query
     * @return True if the address is authorized to sign price data
     */
    function isAuthorizedSigner(address signer) external view returns (bool);
}
