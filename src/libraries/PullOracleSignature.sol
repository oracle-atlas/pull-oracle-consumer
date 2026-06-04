// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {MAX_LOW_S_VALUE, ECRECOVER_PRECOMPILE_ADDR} from "constants/Constants.sol";

/**
 * @title PullOracleSignature
 * @notice Ultra-low gas signature recovery engine for the Pull Oracle protocol
 * @dev Handles raw ECDSA recovery with EIP-2 malleability protection using inline assembly
 */
library PullOracleSignature {
    // Pre-computed error selector for `error InvalidSignatureS()`
    bytes4 internal constant INVALID_SIGNATURE_S_SELECTOR = 0xbf4bf5b8;
    // Pre-computed error selector for `error PrecompileCallFailed()`
    bytes4 internal constant PRECOMPILE_CALL_FAILED_SELECTOR = 0xfd23ff64;
    // Pre-computed error selector for `error SignatureRecoveryFailed()`
    bytes4 internal constant SIGNATURE_RECOVERY_FAILED_SELECTOR = 0x6942c802;

    /**
     * @notice Recover the signer address from raw oracle metadata
     * @dev Parameters 'payloadStart' and 'payloadEnd' are derived from _parseMetadata
     * with guaranteed validity. For gas optimization:
     * - No redundant validation is performed on the input parameters within this scope
     * @param payloadStart Starting byte offset of the data packages in calldata
     * @param payloadEnd Byte offset immediately after the last data package (points to the count byte)
     * @return signer The recovered address (reverts if recovery fails)
     */
    function _recoverSigner(uint256 payloadStart, uint256 payloadEnd) internal view returns (address signer) {
        assembly ("memory-safe") {
            // Derive the signature offset: signature starts one byte after payloadEnd (skip count byte)
            let sigOffset := add(payloadEnd, 1)

            // EIP-2 Malleability Check (Early Fail)
            // Loading 's' directly from calldata is cheaper than copying to memory first if it reverts
            if gt(calldataload(add(sigOffset, 32)), MAX_LOW_S_VALUE) {
                mstore(0x00, INVALID_SIGNATURE_S_SELECTOR)
                revert(0x00, 0x04)
            }

            let ptr := mload(0x40)

            // Calculate the total length of the signed data: packages + 1 byte for count
            let signedLen := sub(sigOffset, payloadStart)
            // Copy the raw signed payload [Packages][Count] directly to memory for hashing
            calldatacopy(ptr, payloadStart, signedLen)

            // Omitting EIP-191 prefix reduces computational burden on the service and minimizes gas consumption for contract recovery
            mstore(ptr, keccak256(ptr, signedLen))

            // Copy 'r' and 's' (64 bytes) directly from calldata to the ecrecover buffer
            // This reduces stack pressure by avoiding separate let variables for 'r' and 's'
            calldatacopy(add(ptr, 64), sigOffset, 64)

            // Populate 'v' to finalize ecrecover input layout: [hash][v][r][s]
            mstore(add(ptr, 32), byte(0, calldataload(add(sigOffset, 64))))

            // Execute staticcall to ecrecover precompile
            // Using memory address 0x00 for output to utilize scratch space and save gas
            if iszero(staticcall(gas(), ECRECOVER_PRECOMPILE_ADDR, ptr, 128, 0x00, 32)) {
                mstore(0x00, PRECOMPILE_CALL_FAILED_SELECTOR)
                revert(0x00, 0x04)
            }

            // Revert if ecrecover returned empty data (invalid v/r/s parameters)
            if iszero(returndatasize()) {
                mstore(0x00, SIGNATURE_RECOVERY_FAILED_SELECTOR)
                revert(0x00, 0x04)
            }

            // Retrieve the recovered address from the scratch space
            signer := mload(0x00)

            // Update the free memory pointer to cover the larger of signedLen and 128 (ecrecover input size),
            // rounded up to a 32-byte boundary to maintain Solidity's memory alignment invariant.
            let size := signedLen
            if lt(signedLen, 128) {
                size := 128
            }
            mstore(0x40, add(ptr, and(add(size, 31), not(31))))
        }
    }
}
