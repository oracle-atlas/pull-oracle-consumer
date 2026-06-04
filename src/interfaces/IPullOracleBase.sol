// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/**
 * @title IPullOracleBase
 * @notice Interface defining centralized base errors for the Pull Oracle protocol
 * @dev Standardized for efficient error handling in both single and batch data processing
 */
interface IPullOracleBase {
    // Thrown when calldata is shorter than the required footer size (68 bytes)
    error InsufficientMetadata();

    // Thrown when the 2-byte magic marker at the end of calldata is incorrect
    error InvalidMarker();

    // Thrown when the encoded package count is zero
    error ZeroPackageCount();

    // Thrown when the number of packages N exceeds the consumer's safety limit
    error ExceedsMaxPackageCount(uint256 count, uint256 max);

    // Thrown when the calldata length does not match the declared number of feed packages
    error InsufficientFeedPackages();

    // Thrown when the signature's 's' value is in the upper half of the curve order (High-S)
    error InvalidSignatureS();

    // Thrown when the staticcall to the ecrecover precompile fails
    // This usually indicates an Out-of-Gas condition or a critical EVM execution error
    error PrecompileCallFailed();

    // Thrown when ecrecover returns empty data (invalid v/r/s parameters cause recovery to fail)
    error SignatureRecoveryFailed();

    // Thrown when a requested feed ID cannot be matched within the provided data packages
    error UnmatchedFeedID(bytes4 feedId);

    // Thrown when the recovered signer address is not authorized
    error UnauthorizedSigner(address recoveredSigner);
}
