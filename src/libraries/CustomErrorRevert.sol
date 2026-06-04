// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/**
 * @title CustomErrorRevert
 * @notice Gas-efficient library for throwing custom errors via inline assembly
 * @dev Engineered to bypass standard Solidity error encoding for minimal gas overhead
 * Key optimizations:
 * - Manual memory management for error selector and argument storage
 * - Atomic revert execution with precise data sizing (0x04 to 0x24 bytes)
 * - Optimized for single-address argument errors to avoid redundant ABI encoding
 */
library CustomErrorRevert {
    /**
     * @dev Execute gas-efficient revert using a 4-byte error selector
     * @param selector The 4-byte error selector to throw
     */
    function revertWith(bytes4 selector) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 0x04)
        }
    }

    /**
     * @dev Execute gas-efficient revert with an error selector and an address argument
     * @param selector The 4-byte error selector to throw
     * @param addr The address value to include in the error data
     */
    function revertWith(bytes4 selector, address addr) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            // Omit explicit masking as compiler ensures clean higher order bits for address arguments
            mstore(0x04, addr)
            revert(0, 0x24)
        }
    }

    /**
     * @dev Execute gas-efficient revert with feed ID and dual timestamp arguments
     * @param selector The 4-byte error selector to throw
     * @param feedId The 4-byte asset identifier
     * @param ts The parsed off-chain timestamp
     * @param current The current on-chain block timestamp
     */
    function revertWithFeedIdAndDualTimestamps(
        bytes4 selector,
        bytes4 feedId,
        uint256 ts,
        uint256 current
    ) internal pure {
        assembly {
            mstore(0, selector)
            mstore(0x04, feedId)
            // @dev Overlaps with FMP at 0x40; safe here as revert terminates execution immediately
            mstore(0x24, ts)
            // @dev Overlaps with Zero Slot at 0x60; safe here as revert terminates execution immediately
            mstore(0x44, current)
            revert(0, 0x64)
        }
    }
}
