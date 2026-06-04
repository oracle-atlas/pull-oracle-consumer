# Pull Oracle Consumer SDK

A gas-optimized Solidity SDK for consuming pull-based oracle price feeds. Contracts inherit the SDK to cryptographically verify signed price data appended to transaction calldata, with zero external calls and minimal on-chain overhead.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Which Consumer to Use](#which-consumer-to-use)
- [Wire Format](#wire-format)
- [Installation](#installation)
- [Usage](#usage)
- [Examples](#examples)
- [Development](#development)
- [Security](#security)
- [License](#license)

## Overview

The Pull Oracle Consumer SDK enables on-chain contracts to verify and decode signed price feeds delivered via trailing calldata. The relay service appends a signed payload to the end of a normal function call, and the consumer transparently parses, authenticates, and returns verified price data — all within a single transaction.

**Key features:**

- All feed packages in a single payload share one ECDSA signature — the on-chain consumer pays the `ecrecover` cost only once per call, regardless of how many feeds are requested
- Inline assembly throughout for minimal gas overhead
- No external contract calls — fully self-contained
- Two performance tiers: Standard (O(M×N) batch) and Transient (O(M+N) batch via EIP-1153)
- Two configuration strategies: hardcoded (zero SLOAD) and storage-backed (runtime governance)
- Comprehensive timestamp validation (staleness + future drift protection)

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Your Protocol Contract                       │
│                     (inherits one of the four consumers)             │
└─────────────────────────────────┬────────────────────────────────────┘
                                  │ calls _getVerifiedFeedData(...)
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       PullOracleConsumerBase                         │
│                                                                      │
│  ┌──────────────────┐  ┌─────────────────────┐  ┌──────────────────┐ │
│  │ PullOracleCodec  │  │ PullOracleSignature │  │  Hook Functions  │ │
│  │ (payload decode) │  │  (ECDSA recovery)   │  │  (configurable)  │ │
│  └──────────────────┘  └─────────────────────┘  └──────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

The four consumer contracts:

1. **PullOracleConsumerStandard** (`src/PullOracleConsumerStandard.sol`) — hardcoded hooks, O(M×N) batch
2. **PullOracleConsumerStandardStorage** (`src/PullOracleConsumerStandardStorage.sol`) — storage-backed hooks, O(M×N) batch
3. **PullOracleConsumerTransient** (`src-advanced/PullOracleConsumerTransient.sol`) — hardcoded hooks, O(M+N) batch (EIP-1153)
4. **PullOracleConsumerTransientStorage** (`src-advanced/PullOracleConsumerTransientStorage.sol`) — storage-backed hooks, O(M+N) batch (EIP-1153)

## Which Consumer to Use

| Variant | Solidity | Min. EVM | Batch Complexity | Hooks | Use Case |
|---------|----------|----------|------------------|-------|----------|
| **Standard** | ≥0.8.13 | ≥Paris | O(M×N) | Hardcoded (0 SLOAD) | Maximum gas efficiency, broad chain compatibility |
| **StandardStorage** | ≥0.8.13 | ≥Paris | O(M×N) | Storage-backed | Runtime governance (signer rotation, threshold tuning) |
| **Transient** | ≥0.8.24 | ≥Cancun | O(M+N) | Hardcoded (0 SLOAD) | Large batch requests on Cancun-compatible chains |
| **TransientStorage** | ≥0.8.24 | ≥Cancun | O(M+N) | Storage-backed | Large batches + runtime governance |

> **Note:** Lower algorithmic complexity does not always mean lower gas cost. The Transient variants incur TSTORE/TLOAD setup overhead that only pays off when `M × N` is sufficiently large. Benchmark both paths against your expected workload.

## Wire Format

Oracle data is appended to the end of normal calldata. The official TypeScript SDK provides helpers to fetch signed oracle payloads from the service, append them to your business calldata, and submit the assembled transaction on-chain.

```
[Business Calldata] [Feed Packages × N] [Footer (68 bytes)]

Feed Package (20 bytes):
┌──────────┬────────────────┬───────────────┐
│ Feed ID  │     Price      │  Timestamp    │
│ (4 bytes)│   (10 bytes)   │  (6 bytes)    │
└──────────┴────────────────┴───────────────┘

Footer (68 bytes):
┌───────────────┬─────────────────────────┬──────────────────┐
│ Package Count │    ECDSA Signature      │  Magic Marker    │
│   (1 byte)    │      (65 bytes)         │   (2 bytes)      │
└───────────────┴─────────────────────────┴──────────────────┘
```

- **Price**: 80-bit unsigned integer (18 decimal precision)
- **Timestamp**: 48-bit Unix timestamp (off-chain aggregation time)
- **Magic Marker**: `0x7096` (derived from `keccak256("ATLAS")`)

## Installation

### Foundry

```bash
forge install oracle-atlas/pull-oracle-consumer
```

Or add as a git submodule:

```bash
git submodule add https://github.com/oracle-atlas/pull-oracle-consumer.git lib/pull-oracle-consumer
```

Add to your `remappings.txt`:

```
pull-oracle-consumer/=lib/pull-oracle-consumer/src/
```

### Hardhat

```bash
npm install @atlas-oracle/pull-oracle-consumer
# or
yarn add @atlas-oracle/pull-oracle-consumer
```

Import directly from `node_modules`:

```solidity
import {PullOracleConsumerStandard} from "@atlas-oracle/pull-oracle-consumer/src/PullOracleConsumerStandard.sol";
```

Configure the Solidity compiler in `hardhat.config.ts`:

```typescript
const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      { version: "0.8.13", settings: { evmVersion: "paris" } },
      // Add if using Transient variants:
      // { version: "0.8.24", settings: { evmVersion: "cancun" } },
    ],
  },
};
```

## Usage

### Minimal Integration (Standard)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {PullOracleConsumerStandard} from "pull-oracle-consumer/PullOracleConsumerStandard.sol";

contract MyProtocol is PullOracleConsumerStandard {
    bytes4 internal constant BTC_USD = 0x00000001;

    function settle() external {
        (uint256 price, uint256 timestamp) = _getVerifiedFeedData(BTC_USD);
        // Use verified price in your business logic...
    }
}
```

### Available Data Accessor Functions

| Function | Behavior | Availability |
|----------|----------|--------------|
| `_getVerifiedFeedData(feedId)` | Single feed, reverts if missing | All variants |
| `_getVerifiedFeedDataLenient(feedId)` | Single feed, returns (0,0) if missing | All variants |
| `_getVerifiedFeedDataBatch(feedIds)` | Batch O(M×N), reverts if any missing | All variants |
| `_getVerifiedFeedDataBatchLenient(feedIds)` | Batch O(M×N), returns 0 for missing | All variants |
| `_getVerifiedFeedDataBatchTransient(feedIds)` | Batch O(M+N), reverts if any missing | Transient variants only |
| `_getVerifiedFeedDataBatchLenientTransient(feedIds)` | Batch O(M+N), returns 0 for missing | Transient variants only |

### Storage-Backed Consumer (Governance)

```solidity
import {PullOracleConsumerStandardStorage} from "pull-oracle-consumer/PullOracleConsumerStandardStorage.sol";

contract MyProtocol is PullOracleConsumerStandardStorage {
    constructor(address[] memory signers)
        PullOracleConsumerStandardStorage(
            255,    // maxPackageCount
            180,    // maxDelay (seconds)
            60,     // maxFutureDrift (seconds)
            signers
        )
    {}

    // Expose governance setters behind access control:
    function rotateSigner(address signer, bool status) external onlyAdmin {
        _setSignerStatus(signer, status);
    }
}
```

### Hook Overrides (Hardcoded Variants)

The hardcoded consumers (`PullOracleConsumerStandard`, `PullOracleConsumerTransient`) delegate security policy to three virtual hook functions. Without any overrides, the contract uses the default implementation provided by `PullOracleReferenceHooks` — no additional configuration is required and the consumer works out of the box.

However, the reference defaults may not suit every protocol. **Integrators should evaluate whether these defaults align with their security model and operational requirements, and override the corresponding hooks if they do not.**

#### The Three Hook Functions

| Hook | Responsibility | Parameter | Default | Description |
|------|---------------|-----------|---------|-------------|
| `_validateTimestamp` | Enforce price freshness | maxDelay | 180s | Revert if price older than this |
| | | maxFutureDrift | 60s | Revert if price timestamp ahead of block by this |
| `_getMaxPackageCount` | Cap gas per call | maxPackageCount | 255 | Maximum feed packages allowed |
| `_isAuthorizedSigner` | Verify oracle signer | authorizedSigner | `0x59eD...600` | Atlas Oracle official signing key |

Each hook is a compile-time constant override (no SLOAD), preserving the gas-efficiency guarantee of the hardcoded consumer.

For complete override examples of all three hooks, see [`examples/standard/ExamplePullOracleConsumerStandard.sol`](examples/standard/ExamplePullOracleConsumerStandard.sol).

> **Recommendation:** Review the reference defaults in `PullOracleReferenceHooks` and determine whether they align with your protocol's latency tolerance, gas budget, and trust assumptions. If not, override the corresponding hooks. Refer to the official oracle documentation for the current production signing address.

## Examples

Complete integration examples are provided under `examples/`. Use these as reference implementations when building your own consumer contracts — each file is a self-contained, compilable contract that you can copy and adapt to your protocol's needs.

```
examples/
├── standard/
│   ├── ExamplePullOracleConsumerStandard.sol           # Hardcoded hooks, 4 API patterns
│   └── ExamplePullOracleConsumerStandardStorage.sol    # Storage governance, 4 API patterns
└── advanced/
    ├── ExamplePullOracleConsumerTransient.sol           # Transient batch, 6 API patterns
    └── ExamplePullOracleConsumerTransientStorage.sol    # Transient + governance, 6 API patterns
```

Each example demonstrates:
- All available data accessor functions with return value consumption
- Business logic placeholder guidance
- Hook override patterns (hardcoded variants)
- Governance setter patterns (storage variants)

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.

```bash
forge build                                 # Build Standard (solc 0.8.13, Paris)
FOUNDRY_PROFILE=advanced forge build        # Build Advanced (solc 0.8.24, Cancun)
FOUNDRY_PROFILE=examples-standard forge build   # Build Standard examples
FOUNDRY_PROFILE=examples-advanced forge build   # Build Advanced examples

forge test                                  # Run Standard tests
FOUNDRY_PROFILE=advanced forge test         # Run Advanced tests
```

## Security

This SDK has been audited by **CertiK**. Key security properties:

- **ECDSA malleability protection** — EIP-2 low-S enforcement prevents signature replay with flipped `s` values
- **Timestamp validation** — Configurable staleness and future-drift bounds per feed
- **Memory safety** — All assembly blocks annotated `("memory-safe")`; free memory pointer 32-byte aligned after use
- **Transient storage isolation** — Batch functions always clear TSTORE slots after use to prevent cross-call data leakage within a transaction

## License

BUSL-1.1 (Business Source License 1.1)
