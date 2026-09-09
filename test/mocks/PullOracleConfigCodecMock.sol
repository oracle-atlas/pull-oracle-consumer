// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {PullOracleConfigCodec, PackedConfig} from "src/libraries/PullOracleConfigCodec.sol";

/**
 * Provide external access to the internal config-codec library functions for
 * unit testing. Foundry tests reach these internals directly; the Tron suite
 * (JS) can only call external entry points, hence this wrapper.
 */
contract PullOracleConfigCodecMock {
    function packConfig(uint8 maxPackageCount, uint48 maxDelay, uint48 maxFutureDrift) external pure returns (bytes32) {
        return PackedConfig.unwrap(PullOracleConfigCodec._packConfig(maxPackageCount, maxDelay, maxFutureDrift));
    }

    function extractMaxPackageCount(bytes32 config) external pure returns (uint256) {
        return PullOracleConfigCodec._extractMaxPackageCount(PackedConfig.wrap(config));
    }

    function extractMaxDelay(bytes32 config) external pure returns (uint256) {
        return PullOracleConfigCodec._extractMaxDelay(PackedConfig.wrap(config));
    }

    function extractMaxFutureDrift(bytes32 config) external pure returns (uint256) {
        return PullOracleConfigCodec._extractMaxFutureDrift(PackedConfig.wrap(config));
    }

    function extractTimestampThresholds(bytes32 config) external pure returns (uint256, uint256) {
        return PullOracleConfigCodec._extractTimestampThresholds(PackedConfig.wrap(config));
    }

    function updateMaxPackageCount(
        bytes32 config,
        uint8 newValue
    ) external pure returns (bytes32 newConfig, uint256 oldValue) {
        (PackedConfig wrapped, uint256 previous) = PullOracleConfigCodec._updateMaxPackageCount(
            PackedConfig.wrap(config),
            newValue
        );
        newConfig = PackedConfig.unwrap(wrapped);
        oldValue = previous;
    }

    function updateMaxDelay(
        bytes32 config,
        uint48 newValue
    ) external pure returns (bytes32 newConfig, uint256 oldValue) {
        (PackedConfig wrapped, uint256 previous) = PullOracleConfigCodec._updateMaxDelay(
            PackedConfig.wrap(config),
            newValue
        );
        newConfig = PackedConfig.unwrap(wrapped);
        oldValue = previous;
    }

    function updateMaxFutureDrift(
        bytes32 config,
        uint48 newValue
    ) external pure returns (bytes32 newConfig, uint256 oldValue) {
        (PackedConfig wrapped, uint256 previous) = PullOracleConfigCodec._updateMaxFutureDrift(
            PackedConfig.wrap(config),
            newValue
        );
        newConfig = PackedConfig.unwrap(wrapped);
        oldValue = previous;
    }
}
