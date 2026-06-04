// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

// Pre-shifted marker for assembly validation: (MAGIC_MARKER << 240)
// The magic marker is 0x7096, derived from the first two bytes of keccak256("ATLAS")
uint256 constant LEFT_SHIFTED_MAGIC_MARKER = 0x7096000000000000000000000000000000000000000000000000000000000000;

// Size of an individual price data package: [4B FeedID] [10B Price] [6B Timestamp] = 20 bytes
uint256 constant FEED_PACKAGE_SIZE = 20;

// Absolute minimum bytes for a valid call as 4 (Selector) + 20 (At least one package) + 68 (Footer) = 92 bytes
uint256 constant MIN_CALLDATA_SIZE = 92;

// Size of the trailing magic marker: [2B Marker]
uint256 constant MARKER_SIZE = 2;

// Footer layout: [1B Count] [65B Signature] [2B Marker] = 68 bytes
uint256 constant FOOTER_SIZE = 68;

// Maximum allowed value for the 's' component of a signature to prevent malleability (EIP-2)
// Corresponds to secp256k1 equation: floor(n / 2), where n is the curve order with its value 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141
uint256 constant MAX_LOW_S_VALUE = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

// Address of the ecrecover precompiled contract
uint256 constant ECRECOVER_PRECOMPILE_ADDR = 0x01;

// Mask to isolate the left-aligned 4-byte feed ID from a 32-byte word
uint256 constant FEED_ID_MASK = 0xffffffff00000000000000000000000000000000000000000000000000000000;

// Size of a standard EVM function selector
uint256 constant SELECTOR_SIZE = 4;
