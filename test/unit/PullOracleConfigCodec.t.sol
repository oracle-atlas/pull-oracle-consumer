// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {PullOracleConfigCodec, PackedConfig} from "libraries/PullOracleConfigCodec.sol";

/**
 * Complete test suite for PullOracleConfigCodec covering encoding, decoding,
 * mutation, roundtrip integrity, field isolation, and boundary conditions.
 */
contract PullOracleConfigCodecTest is Test {
    using PullOracleConfigCodec for PackedConfig;

    /* ————————————————————————————————————————————————————————————————————————
                                ENCODING TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Validate packing with known concrete values and verify raw bit layout.
     */
    function test_PackConfig_ConcreteValues() public pure {
        uint8 count = 10;
        uint48 delay = 60;
        uint48 drift = 30;

        PackedConfig config = PullOracleConfigCodec._packConfig(count, delay, drift);

        // Verify raw layout: count at bits [103:96], delay at [95:48], drift at [47:0]
        bytes32 expected = bytes32((uint256(count) << 96) | (uint256(delay) << 48) | uint256(drift));
        assertEq(PackedConfig.unwrap(config), expected);
    }

    /**
     * Validate packing at maximum boundary values for all three fields.
     */
    function test_PackConfig_MaxBoundary() public pure {
        uint8 count = type(uint8).max;
        uint48 delay = type(uint48).max;
        uint48 drift = type(uint48).max;

        PackedConfig config = PullOracleConfigCodec._packConfig(count, delay, drift);

        bytes32 expected = bytes32((uint256(count) << 96) | (uint256(delay) << 48) | uint256(drift));
        assertEq(PackedConfig.unwrap(config), expected);
    }

    /**
     * Validate packing at minimum boundary (all zeros).
     */
    function test_PackConfig_AllZeros() public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(0, 0, 0);
        assertEq(PackedConfig.unwrap(config), bytes32(0));
    }

    /**
     * Validate that bits [255:104] remain zeroed after packing arbitrary values.
     */
    function test_PackConfig_UpperBitsZeroed_Fuzz(uint8 count, uint48 delay, uint48 drift) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(count, delay, drift);

        // Mask out the valid 104 bits — remainder must be zero
        uint256 raw = uint256(PackedConfig.unwrap(config));
        uint256 upperBits = raw >> 104;
        assertEq(upperBits, 0);
    }

    /* ————————————————————————————————————————————————————————————————————————
                                DECODING TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Validate individual field extraction with known concrete values.
     */
    function test_Extract_ConcreteValues() public pure {
        uint8 count = 10;
        uint48 delay = 60;
        uint48 drift = 30;

        PackedConfig config = PullOracleConfigCodec._packConfig(count, delay, drift);

        assertEq(config._extractMaxPackageCount(), uint256(count));
        assertEq(config._extractMaxDelay(), uint256(delay));
        assertEq(config._extractMaxFutureDrift(), uint256(drift));
    }

    /**
     * Validate extraction at maximum boundary values.
     */
    function test_Extract_MaxBoundary() public pure {
        uint8 count = type(uint8).max;
        uint48 delay = type(uint48).max;
        uint48 drift = type(uint48).max;

        PackedConfig config = PullOracleConfigCodec._packConfig(count, delay, drift);

        assertEq(config._extractMaxPackageCount(), uint256(count));
        assertEq(config._extractMaxDelay(), uint256(delay));
        assertEq(config._extractMaxFutureDrift(), uint256(drift));
    }

    /**
     * Validate that _extractTimestampThresholds returns identical results to individual extractors.
     */
    function test_ExtractTimestampThresholds_Consistency_Fuzz(uint8 count, uint48 delay, uint48 drift) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(count, delay, drift);

        (uint256 combinedDelay, uint256 combinedDrift) = config._extractTimestampThresholds();

        assertEq(combinedDelay, config._extractMaxDelay());
        assertEq(combinedDrift, config._extractMaxFutureDrift());
    }

    /* ————————————————————————————————————————————————————————————————————————
                            ROUNDTRIP (PACK → EXTRACT) FUZZ
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Verify lossless roundtrip: pack arbitrary values and extract them back unchanged.
     */
    function test_Roundtrip_Fuzz(uint8 count, uint48 delay, uint48 drift) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(count, delay, drift);

        assertEq(config._extractMaxPackageCount(), uint256(count));
        assertEq(config._extractMaxDelay(), uint256(delay));
        assertEq(config._extractMaxFutureDrift(), uint256(drift));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            FIELD ISOLATION TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Verify that setting only maxPackageCount leaves the other fields at zero.
     */
    function test_Isolation_OnlyMaxPackageCount_Fuzz(uint8 count) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(count, 0, 0);

        assertEq(config._extractMaxPackageCount(), uint256(count));
        assertEq(config._extractMaxDelay(), 0);
        assertEq(config._extractMaxFutureDrift(), 0);
    }

    /**
     * Verify that setting only maxDelay leaves the other fields at zero.
     */
    function test_Isolation_OnlyMaxDelay_Fuzz(uint48 delay) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(0, delay, 0);

        assertEq(config._extractMaxPackageCount(), 0);
        assertEq(config._extractMaxDelay(), uint256(delay));
        assertEq(config._extractMaxFutureDrift(), 0);
    }

    /**
     * Verify that setting only maxFutureDrift leaves the other fields at zero.
     */
    function test_Isolation_OnlyMaxFutureDrift_Fuzz(uint48 drift) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(0, 0, drift);

        assertEq(config._extractMaxPackageCount(), 0);
        assertEq(config._extractMaxDelay(), 0);
        assertEq(config._extractMaxFutureDrift(), uint256(drift));
    }

    /* ————————————————————————————————————————————————————————————————————————
                                MUTATION TESTS
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Validate XOR-swap mutation of maxPackageCount with concrete values.
     */
    function test_UpdateMaxPackageCount_Concrete() public pure {
        uint8 initCount = 10;
        uint48 initDelay = 60;
        uint48 initDrift = 30;
        uint8 newCount = 20;

        PackedConfig config = PullOracleConfigCodec._packConfig(initCount, initDelay, initDrift);

        (PackedConfig newConfig, uint256 oldValue) = config._updateMaxPackageCount(newCount);
        assertEq(oldValue, uint256(initCount));
        assertEq(newConfig._extractMaxPackageCount(), uint256(newCount));
        assertEq(newConfig._extractMaxDelay(), uint256(initDelay));
        assertEq(newConfig._extractMaxFutureDrift(), uint256(initDrift));
    }

    /**
     * Validate XOR-swap mutation of maxDelay with concrete values.
     */
    function test_UpdateMaxDelay_Concrete() public pure {
        uint8 initCount = 10;
        uint48 initDelay = 60;
        uint48 initDrift = 30;
        uint48 newDelay = 300;

        PackedConfig config = PullOracleConfigCodec._packConfig(initCount, initDelay, initDrift);

        (PackedConfig newConfig, uint256 oldValue) = config._updateMaxDelay(newDelay);
        assertEq(oldValue, uint256(initDelay));
        assertEq(newConfig._extractMaxDelay(), uint256(newDelay));
        assertEq(newConfig._extractMaxPackageCount(), uint256(initCount));
        assertEq(newConfig._extractMaxFutureDrift(), uint256(initDrift));
    }

    /**
     * Validate XOR-swap mutation of maxFutureDrift with concrete values.
     */
    function test_UpdateMaxFutureDrift_Concrete() public pure {
        uint8 initCount = 10;
        uint48 initDelay = 60;
        uint48 initDrift = 30;
        uint48 newDrift = 120;

        PackedConfig config = PullOracleConfigCodec._packConfig(initCount, initDelay, initDrift);

        (PackedConfig newConfig, uint256 oldValue) = config._updateMaxFutureDrift(newDrift);
        assertEq(oldValue, uint256(initDrift));
        assertEq(newConfig._extractMaxFutureDrift(), uint256(newDrift));
        assertEq(newConfig._extractMaxPackageCount(), uint256(initCount));
        assertEq(newConfig._extractMaxDelay(), uint256(initDelay));
    }

    /**
     * Fuzz: mutate maxPackageCount and verify roundtrip + field isolation.
     */
    function test_UpdateMaxPackageCount_Fuzz(
        uint8 initCount,
        uint48 initDelay,
        uint48 initDrift,
        uint8 newCount
    ) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(initCount, initDelay, initDrift);

        (PackedConfig newConfig, uint256 oldValue) = config._updateMaxPackageCount(newCount);
        assertEq(oldValue, uint256(initCount));
        assertEq(newConfig._extractMaxPackageCount(), uint256(newCount));
        assertEq(newConfig._extractMaxDelay(), uint256(initDelay));
        assertEq(newConfig._extractMaxFutureDrift(), uint256(initDrift));
    }

    /**
     * Fuzz: mutate maxDelay and verify roundtrip + field isolation.
     */
    function test_UpdateMaxDelay_Fuzz(
        uint8 initCount,
        uint48 initDelay,
        uint48 initDrift,
        uint48 newDelay
    ) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(initCount, initDelay, initDrift);

        (PackedConfig newConfig, uint256 oldValue) = config._updateMaxDelay(newDelay);
        assertEq(oldValue, uint256(initDelay));
        assertEq(newConfig._extractMaxDelay(), uint256(newDelay));
        assertEq(newConfig._extractMaxPackageCount(), uint256(initCount));
        assertEq(newConfig._extractMaxFutureDrift(), uint256(initDrift));
    }

    /**
     * Fuzz: mutate maxFutureDrift and verify roundtrip + field isolation.
     */
    function test_UpdateMaxFutureDrift_Fuzz(
        uint8 initCount,
        uint48 initDelay,
        uint48 initDrift,
        uint48 newDrift
    ) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(initCount, initDelay, initDrift);

        (PackedConfig newConfig, uint256 oldValue) = config._updateMaxFutureDrift(newDrift);
        assertEq(oldValue, uint256(initDrift));
        assertEq(newConfig._extractMaxFutureDrift(), uint256(newDrift));
        assertEq(newConfig._extractMaxPackageCount(), uint256(initCount));
        assertEq(newConfig._extractMaxDelay(), uint256(initDelay));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            MUTATION IDEMPOTENCY
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Verify that updating a field to its current value produces an identical config word.
     */
    function test_UpdateIdempotent_Fuzz(uint8 count, uint48 delay, uint48 drift) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(count, delay, drift);

        (PackedConfig afterCount, ) = config._updateMaxPackageCount(count);
        assertEq(PackedConfig.unwrap(afterCount), PackedConfig.unwrap(config));

        (PackedConfig afterDelay, ) = config._updateMaxDelay(delay);
        assertEq(PackedConfig.unwrap(afterDelay), PackedConfig.unwrap(config));

        (PackedConfig afterDrift, ) = config._updateMaxFutureDrift(drift);
        assertEq(PackedConfig.unwrap(afterDrift), PackedConfig.unwrap(config));
    }

    /* ————————————————————————————————————————————————————————————————————————
                            SEQUENTIAL MUTATION
    ————————————————————————————————————————————————————————————————————————— */

    /**
     * Verify that chaining all three mutations produces the same result as a fresh pack.
     */
    function test_SequentialMutation_Fuzz(
        uint8 count1,
        uint48 delay1,
        uint48 drift1,
        uint8 count2,
        uint48 delay2,
        uint48 drift2
    ) public pure {
        PackedConfig config = PullOracleConfigCodec._packConfig(count1, delay1, drift1);
        (config, ) = config._updateMaxPackageCount(count2);
        (config, ) = config._updateMaxDelay(delay2);
        (config, ) = config._updateMaxFutureDrift(drift2);

        // Compare against a fresh pack with the final values
        PackedConfig fresh = PullOracleConfigCodec._packConfig(count2, delay2, drift2);
        assertEq(PackedConfig.unwrap(config), PackedConfig.unwrap(fresh));
    }
}
