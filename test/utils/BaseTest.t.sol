// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {LEFT_SHIFTED_MAGIC_MARKER} from "constants/Constants.sol";

/**
 * Centralized testing utility contract for the Pull Oracle protocol
 * This abstract contract provides core primitives for building validly signed oracle payloads.
 */
abstract contract BaseTest is Test {
    // Define the primary authorized signer private key
    uint256 internal constant PRIMARY_SIGNER_PK = 0x3984ba7c2f5d0b43eeed79c2f6498969596432ddce18ba031ef1a6d78b15c55b;

    // Define the authorized secondary signer private key
    uint256 internal constant SECONDARY_SIGNER_PK = 0xcdfdcba39f49d5858113d6b142ee2128407bd65a9604af271a9cf31a32009131;

    // Define the unauthorized signer private key
    uint256 internal constant UNAUTHORIZED_SIGNER_PK = 0x01;

    address internal immutable PRIMARY_SIGNER = vm.addr(PRIMARY_SIGNER_PK);
    address internal immutable SECONDARY_SIGNER = vm.addr(SECONDARY_SIGNER_PK);
    address internal immutable UNAUTHORIZED_SIGNER = vm.addr(UNAUTHORIZED_SIGNER_PK);

    // Extract the 2-byte magic marker from the high-order constant
    // forge-lint: disable-next-line(unsafe-typecast)
    uint16 internal constant MAGIC_MARKER = uint16(LEFT_SHIFTED_MAGIC_MARKER >> 240);

    /**
     * Construct a protocol-compliant extraData payload with a valid ECDSA signature
     * Process input data to generate a signed payload following the [Packages][Count][Sig][Marker] layout.
     */
    function _buildSignedExtraData(
        uint256 signerPrivateKey,
        bytes4[] memory feedIds,
        uint256[] memory prices,
        uint256[] memory timestamps
    ) internal pure returns (bytes memory extraData) {
        uint256 count = feedIds.length;
        bytes memory packages;

        // Iterate through feeds to pack individual 20-byte packages
        for (uint256 i = 0; i < count; ) {
            // Encode data as [ID (4B)][Price (10B)][Timestamp (6B)]
            bytes memory package = abi.encodePacked(feedIds[i], uint80(prices[i]), uint48(timestamps[i]));

            // Append current package to the packages buffer
            packages = abi.encodePacked(packages, package);

            unchecked {
                ++i;
            }
        }

        // Generate the digest by hashing the data identified as 'signed' in the structure
        // Signing scope: [Feed Data Packages] + [Feed Data Count (N)].
        bytes32 digest = keccak256(abi.encodePacked(packages, _toUint8(count)));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Assemble final payload: [Packages][Count (1B)][Signature (65B)][Marker (2B)]
        extraData = abi.encodePacked(packages, _toUint8(count), signature, MAGIC_MARKER);
    }

    /*
     * Build unsigned extra data payload to verify search engine logic without authentication
     */
    function _buildUnsignedExtraData(
        bytes4[] memory feedIds,
        uint256[] memory prices,
        uint256[] memory timestamps
    ) internal pure returns (bytes memory extraData) {
        uint256 count = feedIds.length;
        bytes memory packages;

        // Iterate through feeds to pack individual 32-byte words for calldataload alignment
        for (uint256 i = 0; i < count; ) {
            // Encode data as [ID (4B)][Price (10B)][Timestamp (6B)]
            bytes memory package = abi.encodePacked(feedIds[i], uint80(prices[i]), uint48(timestamps[i]));

            // Append current package to the packages buffer
            packages = abi.encodePacked(packages, package);

            unchecked {
                ++i;
            }
        }

        // Fill signature slot with 65 zero bytes to maintain metadata physical layout
        bytes memory dummySignature = new bytes(65);

        // Assemble unsigned payload: [Packages][Count (1B)][Dummy Signature (65B)][Marker (2B)]
        extraData = abi.encodePacked(packages, _toUint8(count), dummySignature, MAGIC_MARKER);
    }

    /**
     * Append oracle extra data to a standard function call
     */
    function _attachExtraData(
        bytes memory callData,
        bytes memory extraData
    ) internal pure returns (bytes memory fullPayload) {
        return abi.encodePacked(callData, extraData);
    }

    /*
     * Execute direct truncation from uint256 to uint8 without overflow checks
     */
    function _toUint8(uint256 value) internal pure returns (uint8) {
        // casting to 'uint8' is safe because callers ensure value is within 8-bit range
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(value);
    }
}
