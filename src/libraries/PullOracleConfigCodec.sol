// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

type PackedConfig is bytes32;

/**
 * @title PullOracleConfigCodec
 * @notice Assembly-optimized encoding and decoding for the packed oracle config slot
 * @dev Encapsulate all bit-level operations for the three-field packed config word, isolating
 *      layout knowledge from consumer business logic.
 *
 *      Trust Chain: Enforce type isolation via the PackedConfig UDVT to prevent accidental
 *      misuse of raw bytes32 at compile time. All encode and update entry points accept
 *      narrowed Solidity types (uint8, uint48) to enforce bit-width constraints at compile
 *      time, eliminating the need for runtime overflow validation. Decode paths return uint256
 *      for seamless integration with EVM-native arithmetic and the base contract's hook
 *      signatures.
 *
 *      Gas Strategy: PackedConfig unwraps to bytes32 at the EVM level with zero runtime
 *      overhead. Every function is pure stack arithmetic with zero memory allocation. Leverage
 *      the BYTE opcode for single-byte maxPackageCount extraction (3 gas vs 6 for SHR+AND).
 *      Employ XOR-swap for field mutation (9 gas vs 15 for mask-and-set), exploiting the
 *      identity A ⊕ (A ⊕ B) = B to flip only the target bit range.
 *
 *      Packed Layout (right-aligned within bytes32, 13 bytes / 104 bits total):
 *        Bits [103:96]  maxPackageCount  (8 bits  / 1 byte)   shift = 96, byte position = 19
 *        Bits [95:48]   maxDelay         (48 bits / 6 bytes)  shift = 48
 *        Bits [47:0]    maxFutureDrift   (48 bits / 6 bytes)  shift = 0
 *        Bits [255:104] unused (zeroed)
 */
library PullOracleConfigCodec {
    /* ————————————————————————————————————————————————————————————————————————
                                BIT LAYOUT CONSTANTS
    ————————————————————————————————————————————————————————————————————————— */

    // Offset maxDelay past the 48-bit maxFutureDrift field at position zero
    uint256 private constant SHIFT_MAX_DELAY = 48;

    // Offset maxPackageCount past maxFutureDrift (48b) + maxDelay (48b) = 96 bits
    uint256 private constant SHIFT_MAX_PACKAGE_COUNT = 96;

    // Locate maxPackageCount at byte offset 19 from MSB: (256 - 96 - 8) / 8 = 19
    uint256 private constant BYTE_POS_MAX_PACKAGE_COUNT = 19;

    // Isolate 48-bit timestamp threshold fields during extraction
    uint256 private constant MASK_48 = 0xffffffffffff;

    /* ————————————————————————————————————————————————————————————————————————
                                    ENCODING
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Assemble three typed fields into a single packed config word.
     *      Bit-width safety is guaranteed by the Solidity type system at compile time.
     * @param maxPackageCount Package count ceiling
     * @param maxDelay Staleness tolerance in seconds
     * @param maxFutureDrift Future drift tolerance in seconds
     * @return config The assembled packed config word
     */
    function _packConfig(
        uint8 maxPackageCount,
        uint48 maxDelay,
        uint48 maxFutureDrift
    ) internal pure returns (PackedConfig config) {
        assembly ("memory-safe") {
            config := or(
                or(shl(SHIFT_MAX_PACKAGE_COUNT, maxPackageCount), shl(SHIFT_MAX_DELAY, maxDelay)),
                maxFutureDrift
            )
        }
    }

    /* ————————————————————————————————————————————————————————————————————————
                                    DECODING
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Extract the 8-bit package count ceiling from byte position 19.
     *      Use the BYTE opcode for single-instruction extraction (3 gas vs SHR+AND at 6 gas).
     * @param config The packed config word
     * @return result Decoded maxPackageCount value
     */
    function _extractMaxPackageCount(PackedConfig config) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            result := byte(BYTE_POS_MAX_PACKAGE_COUNT, config)
        }
    }

    /**
     * @dev Extract the 48-bit staleness tolerance from bits [95:48].
     * @param config The packed config word
     * @return result Decoded maxDelay value in seconds
     */
    function _extractMaxDelay(PackedConfig config) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            result := and(shr(SHIFT_MAX_DELAY, config), MASK_48)
        }
    }

    /**
     * @dev Extract the 48-bit future drift tolerance from bits [47:0].
     * @param config The packed config word
     * @return result Decoded maxFutureDrift value in seconds
     */
    function _extractMaxFutureDrift(PackedConfig config) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            result := and(config, MASK_48)
        }
    }

    /**
     * @dev Extract both timestamp thresholds in a single call for dual-branch validation.
     *      Designed to pair with a single SLOAD at the call site, yielding two stack values
     *      for the staleness and drift comparisons.
     * @param config The packed config word
     * @return maxDelay Decoded staleness tolerance in seconds
     * @return maxFutureDrift Decoded future drift tolerance in seconds
     */
    function _extractTimestampThresholds(
        PackedConfig config
    ) internal pure returns (uint256 maxDelay, uint256 maxFutureDrift) {
        assembly ("memory-safe") {
            maxDelay := and(shr(SHIFT_MAX_DELAY, config), MASK_48)
            maxFutureDrift := and(config, MASK_48)
        }
    }

    /* ————————————————————————————————————————————————————————————————————————
                                    MUTATION
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * @dev Atomically replace the 8-bit maxPackageCount field via XOR-swap.
     *      Exploit A ⊕ (A ⊕ B) = B to flip only bits [103:96]. Return the previous
     *      value for event emission at the call site.
     * @param config The current packed config word
     * @param newValue Replacement value
     * @return newConfig The updated packed config word
     * @return oldValue The previous maxPackageCount before mutation
     */
    function _updateMaxPackageCount(
        PackedConfig config,
        uint8 newValue
    ) internal pure returns (PackedConfig newConfig, uint256 oldValue) {
        assembly ("memory-safe") {
            oldValue := byte(BYTE_POS_MAX_PACKAGE_COUNT, config)
            newConfig := xor(config, shl(SHIFT_MAX_PACKAGE_COUNT, xor(oldValue, newValue)))
        }
    }

    /**
     * @dev Atomically replace the 48-bit maxDelay field via XOR-swap.
     *      Compute old ⊕ new as a 48-bit diff, shift to bits [95:48], and XOR into the
     *      packed word to flip exactly the target band. Return the previous value for
     *      event emission at the call site.
     * @param config The current packed config word
     * @param newValue Replacement value in seconds
     * @return newConfig The updated packed config word
     * @return oldValue The previous maxDelay before mutation
     */
    function _updateMaxDelay(
        PackedConfig config,
        uint48 newValue
    ) internal pure returns (PackedConfig newConfig, uint256 oldValue) {
        assembly ("memory-safe") {
            oldValue := and(shr(SHIFT_MAX_DELAY, config), MASK_48)
            newConfig := xor(config, shl(SHIFT_MAX_DELAY, xor(oldValue, newValue)))
        }
    }

    /**
     * @dev Atomically replace the 48-bit maxFutureDrift field via XOR-swap.
     *      Since the field occupies bits [47:0] with zero shift, the diff is XORed
     *      directly without positioning. Return the previous value for event emission
     *      at the call site.
     * @param config The current packed config word
     * @param newValue Replacement value in seconds
     * @return newConfig The updated packed config word
     * @return oldValue The previous maxFutureDrift before mutation
     */
    function _updateMaxFutureDrift(
        PackedConfig config,
        uint48 newValue
    ) internal pure returns (PackedConfig newConfig, uint256 oldValue) {
        assembly ("memory-safe") {
            oldValue := and(config, MASK_48)
            newConfig := xor(config, xor(oldValue, newValue))
        }
    }
}
