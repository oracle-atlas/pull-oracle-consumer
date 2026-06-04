// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {IPullOracleBase} from "interfaces/IPullOracleBase.sol";
import {BaseTest} from "test/utils/BaseTest.t.sol";
import {PullOracleCodecMock} from "test/mocks/PullOracleCodecMock.sol";
import {MIN_CALLDATA_SIZE, FEED_PACKAGE_SIZE, FOOTER_SIZE} from "constants/Constants.sol";
import {LowLevelReverter} from "test/utils/LowLevelReverter.sol";

/**
 * Complete test suite covering happy paths, error states, and fuzzing
 */
contract PullOracleCodecTest is BaseTest {
    using LowLevelReverter for address;

    PullOracleCodecMock internal mock = new PullOracleCodecMock();

    /* ————————————————————————————————————————————————————————————————————————
                                HAPPY PATH TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Validate metadata parsing when extraData follows standard function arguments.
     */
    function test_ParseMetadata_WithCalldata() public view {
        uint8 expectedCount = 3;

        bytes memory extraData = _buildSignedExtraData(
            PRIMARY_SIGNER_PK,
            new bytes4[](expectedCount),
            new uint256[](expectedCount),
            new uint256[](expectedCount)
        );

        // Construct: [Selector (4B)] + [uint256 maxCount (32B)] + [extraData]
        bytes memory callData = abi.encodeWithSelector(mock.parseMetadata.selector, uint256(10));
        bytes memory fullPayload = _attachExtraData(callData, extraData);

        // Execute staticcall to mock contract
        (bool success, bytes memory returnData) = address(mock).staticcall(fullPayload);
        assertTrue(success);

        (uint256 resStart, uint256 resEnd) = abi.decode(returnData, (uint256, uint256));
        assertEq(resEnd - resStart, uint256(expectedCount) * FEED_PACKAGE_SIZE);
        assertEq(resStart, callData.length);
        assertEq(resEnd, fullPayload.length - FOOTER_SIZE);
    }

    /**
     * Validate metadata parsing when extraData is the sole payload after the selector.
     */
    function test_ParseMetadata_NoCalldata() public view {
        uint8 expectedCount = 1;

        bytes memory extraData = _buildSignedExtraData(
            PRIMARY_SIGNER_PK,
            new bytes4[](expectedCount),
            new uint256[](expectedCount),
            new uint256[](expectedCount)
        );

        // Construct: [Selector (4B)] + [extraData]
        // @dev Simulate a direct call to a function with no intermediate arguments
        bytes memory callData = abi.encodeWithSelector(mock.parseMetadata.selector);
        bytes memory fullPayload = _attachExtraData(callData, extraData);

        // Execute staticcall to isolate the specific calldata context
        (bool success, bytes memory returnData) = address(mock).staticcall(fullPayload);
        assertTrue(success);

        (uint256 resStart, uint256 resEnd) = abi.decode(returnData, (uint256, uint256));
        assertEq(resEnd - resStart, uint256(expectedCount) * FEED_PACKAGE_SIZE);
        assertEq(resStart, 4);
        assertEq(resEnd, fullPayload.length - FOOTER_SIZE);
    }

    /**
     * Validate successful parsing when count is exactly equal to maxPackageCount
     */
    function test_ParseMetadata_Boundary_MaxCount() public view {
        uint8 count = 10;
        uint256 maxAllowed = count;

        bytes memory extraData = _buildSignedExtraData(
            PRIMARY_SIGNER_PK,
            new bytes4[](count),
            new uint256[](count),
            new uint256[](count)
        );

        bytes memory callData = abi.encodeWithSelector(mock.parseMetadata.selector, maxAllowed);
        bytes memory fullPayload = _attachExtraData(callData, extraData);

        (bool success, ) = address(mock).staticcall(fullPayload);
        assertTrue(success);
    }

    /**
     * Validate metadata parsing resilience against random junk data length.
     * @param junk Random bytes representing arbitrary business calldata
     * @param count Number of packages to parse (clamped for safety)
     */
    function test_ParseMetadata_OffsetResilienceFuzz(bytes calldata junk, uint8 count) public view {
        // Clamp count to prevent exceeding typical test limits
        uint256 maxCount = 20;
        uint256 expectedCount = uint256(bound(count, 1, maxCount));

        bytes memory extraData = _buildSignedExtraData(
            PRIMARY_SIGNER_PK,
            new bytes4[](expectedCount),
            new uint256[](expectedCount),
            new uint256[](expectedCount)
        );

        // Construct: [Selector (4B)] + [uint256 arg (32B)] + [Junk] + [extraData]
        // @dev This simulates a complex transaction where oracle data is appended after dynamic arguments
        bytes memory baseCall = abi.encodeWithSelector(mock.parseMetadata.selector, maxCount);
        bytes memory fullPayload = abi.encodePacked(baseCall, junk, extraData);

        (bool success, bytes memory returnData) = address(mock).staticcall(fullPayload);
        assertTrue(success);

        (uint256 resStart, uint256 resEnd) = abi.decode(returnData, (uint256, uint256));
        assertEq(resEnd - resStart, uint256(expectedCount) * FEED_PACKAGE_SIZE);
        assertEq(resStart, fullPayload.length - extraData.length);
        assertEq(resEnd, fullPayload.length - FOOTER_SIZE);
    }

    /**
     * Ensure pointer arithmetic remains valid at the maximum theoretical package density (255 packages).
     */
    function test_ParseMetadata_MaxDensity() public view {
        uint8 count = type(uint8).max; // 255 packages

        // Construct payload with maximum possible uint8 package count
        bytes memory extraData = _buildSignedExtraData(
            PRIMARY_SIGNER_PK,
            new bytes4[](count),
            new uint256[](count),
            new uint256[](count)
        );

        bytes memory callData = abi.encodeWithSelector(mock.parseMetadata.selector, count);
        bytes memory fullPayload = _attachExtraData(callData, extraData);

        (bool success, bytes memory returnData) = address(mock).staticcall(fullPayload);
        assertTrue(success);

        (uint256 resStart, uint256 resEnd) = abi.decode(returnData, (uint256, uint256));

        // Verify that pointer distance between start and end is exactly N * 20 bytes
        assertEq(resEnd - resStart, uint256(count) * FEED_PACKAGE_SIZE);
        assertEq(resStart, fullPayload.length - extraData.length);
        assertEq(resEnd, fullPayload.length - FOOTER_SIZE);
    }

    /**
     * Validate precise bitwise extraction using Fuzzing with random noise.
     * @param feedId Random 4-byte identifier to simulate MSB noise
     * @param price Random 80-bit price value
     * @param ts Random 48-bit timestamp value
     * @param junk Random 12-byte trailing data to simulate LSB noise
     */
    function test_ParseFeedPackage_Fuzz(bytes4 feedId, uint80 price, uint48 ts, bytes12 junk) public view {
        // Construct word: [FeedID(4B)][Price(10B)][Time(6B)][Junk(12B)]
        bytes32 word = bytes32(feedId) |
            bytes32(uint256(price) << 144) |
            bytes32(uint256(ts) << 96) |
            (bytes32(junk) >> 160);

        (uint256 decodedPrice, uint256 decodedTs) = mock.parseFeedPackage(word);

        assertEq(decodedPrice, uint256(price));
        assertEq(decodedTs, uint256(ts));
    }

    /**
     * Validate bitwise extraction at maximum boundary values.
     */
    function test_ParseFeedPackage_MaxValues() public view {
        uint80 maxPrice = type(uint80).max;
        uint48 maxTs = type(uint48).max;

        // Construct word with maximum values in their respective bit slots
        bytes32 word = bytes32(uint256(maxPrice) << 144) | bytes32(uint256(maxTs) << 96);

        (uint256 decodedPrice, uint256 decodedTs) = mock.parseFeedPackage(word);

        assertEq(decodedPrice, uint256(maxPrice));
        assertEq(decodedTs, uint256(maxTs));
    }

    /**
     * Verify that data in the FeedID and Junk sections does not pollute the results.
     */
    function test_ParseFeedPackage_NoiseIsolation() public view {
        uint80 price = 500 ether;
        uint48 ts = 1710000000;

        // Construct word with maximum noise: [0xFFFFFFFF][Price][Time][0xFF...FF]
        bytes32 wordWithNoise = bytes32(bytes4(0xffffffff)) |
            bytes32(uint256(price) << 144) |
            bytes32(uint256(ts) << 96) |
            bytes32(type(uint256).max >> 160);

        (uint256 decodedPrice, uint256 decodedTs) = mock.parseFeedPackage(wordWithNoise);

        // Verify that noise from both MSB and LSB is correctly stripped
        assertEq(decodedPrice, uint256(price));
        assertEq(decodedTs, uint256(ts));
    }

    /* ————————————————————————————————————————————————————————————————————————
                                NEGATIVE TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Verify revert when calldata length is below the mandatory minimum size
     */
    function test_Revert_InsufficientMetadata() public {
        // Encode the standard function call with 4B selector and 32B uint256 maxPackageCount argument
        bytes memory callData = abi.encodeWithSelector(mock.parseMetadata.selector, uint256(10));

        // Construct insufficient extraData by subtracting 32 to account for the uint256 parameter in callData
        // Subtract additional 1 to fall exactly at MIN_CALLDATA_SIZE - 1
        bytes memory extraData = new bytes(MIN_CALLDATA_SIZE - callData.length - 1);
        bytes memory shortPayload = _attachExtraData(callData, extraData);

        vm.expectRevert(IPullOracleBase.InsufficientMetadata.selector);
        address(mock).revertingStaticcall(shortPayload);
    }

    /**
     * Verify revert when the protocol magic marker is incorrect
     */
    function test_Revert_InvalidMarker() public {
        bytes memory callData = abi.encodeWithSelector(mock.parseMetadata.selector, uint256(10));

        // Construct padding to reach MIN_CALLDATA_SIZE and bypass the initial length check
        // Subtract 2 to leave space for the manual marker injection
        bytes memory padding = new bytes(MIN_CALLDATA_SIZE - callData.length - 2);

        // Construct invalid payload by appending an incorrect magic marker (MAGIC_MARKER + 1)
        bytes memory invalidPayload = abi.encodePacked(callData, padding, MAGIC_MARKER + 1);

        vm.expectRevert(IPullOracleBase.InvalidMarker.selector);
        address(mock).revertingStaticcall(invalidPayload);
    }

    /**
     * Verify revert when the package count is explicitly zero
     */
    function test_Revert_ZeroPackageCount() public {
        // Encode the standard function call with 4B selector and 32B uint256 maxPackageCount argument
        bytes memory callData = abi.encodeWithSelector(mock.parseMetadata.selector, uint256(10));

        // Construct a valid signature buffer and the mandatory magic marker
        bytes memory signature = new bytes(65);

        // Construct invalid payload by explicitly setting the count byte to 0 at the start of the 68B footer
        // Total length: 36 (callData) + 1 (count) + 65 (sig) + 2 (marker) = 104 bytes
        bytes memory invalidPayload = abi.encodePacked(callData, uint8(0), signature, MAGIC_MARKER);

        vm.expectRevert(IPullOracleBase.ZeroPackageCount.selector);
        address(mock).revertingStaticcall(invalidPayload);
    }

    /**
     * Verify revert when the package count exceeds the allowed maximum
     */
    function test_Revert_ExceedsMaxPackageCount() public {
        // Define the maximum allowed packages for this call
        uint256 maxAllowed = 10;
        uint256 actualCount = maxAllowed + 1;

        bytes memory callData = abi.encodeWithSelector(mock.parseMetadata.selector, maxAllowed);
        bytes memory signature = new bytes(65);
        // Construct invalid payload by setting the count byte to 11 (maxAllowed + 1)
        bytes memory invalidPayload = abi.encodePacked(callData, _toUint8(actualCount), signature, MAGIC_MARKER);

        vm.expectRevert(
            abi.encodeWithSelector(IPullOracleBase.ExceedsMaxPackageCount.selector, actualCount, maxAllowed)
        );
        address(mock).revertingStaticcall(invalidPayload);
    }

    /**
     * Verify revert when the declared package count exceeds the available calldata space
     */
    function test_Revert_InsufficientFeedPackages() public {
        uint8 actualPackages = 2;
        uint8 declaredCount = 5;

        bytes memory extraData = _buildSignedExtraData(
            PRIMARY_SIGNER_PK,
            new bytes4[](actualPackages),
            new uint256[](actualPackages),
            new uint256[](actualPackages)
        );

        // Construct a payload where the footer claims more packages than the physical length supports
        extraData[extraData.length - FOOTER_SIZE] = bytes1(declaredCount);
        bytes memory callData = abi.encodeWithSelector(mock.parseMetadata.selector, uint256(20));
        bytes memory invalidPayload = _attachExtraData(callData, extraData);

        vm.expectRevert(IPullOracleBase.InsufficientFeedPackages.selector);
        address(mock).revertingStaticcall(invalidPayload);
    }

    /**
     * Verify revert when the declared count is exactly one greater than the physical package count.
     * This test uses a no-argument function to isolate the physical boundary check and ensure
     * the smallest possible length discrepancy (20 bytes) triggers InsufficientFeedPackages.
     */
    function test_Revert_InsufficientFeedPackages_MinimumGap() public {
        uint8 actualPackages = 2;
        uint8 declaredCount = actualPackages + 1;

        // Construct a valid extraData payload with 2 actual packages
        // Total extraData length: (2 * 20) + 68 = 108B
        bytes memory extraData = _buildSignedExtraData(
            PRIMARY_SIGNER_PK,
            new bytes4[](actualPackages),
            new uint256[](actualPackages),
            new uint256[](actualPackages)
        );

        // Manually overwrite the count byte (at length - 68) to 3
        extraData[extraData.length - FOOTER_SIZE] = bytes1(declaredCount);

        // Construct full payload for the no-arg business function
        // Total physical length: 4 (selector) + 108 (extraData) = 112B
        bytes memory invalidPayload = abi.encodePacked(mock.parseMetadataWithoutBusinessCalldata.selector, extraData);

        // Required threshold: (3 * 20 + 68) + 4 = 132B
        // Current payload length is 112B
        // Revert expected because 112 < 132
        vm.expectRevert(IPullOracleBase.InsufficientFeedPackages.selector);
        address(mock).revertingStaticcall(invalidPayload);
    }
}
