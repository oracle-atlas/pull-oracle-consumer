alias ba := build-advanced
alias ca := clean-advanced
alias ta := test-advanced

# Build project using default profile (Paris)
# Execute standard compilation
build:
    forge build

# Build project using advanced profile (Cancun)
# Enable EIP-1153 opcodes like TSTORE and TLOAD
build-advanced:
    FOUNDRY_PROFILE=advanced forge build

# Run tests using advanced profile
# Execute gas benchmarks with Cancun opcodes
test-advanced:
    FOUNDRY_PROFILE=advanced forge test -vvv

# Purge artifacts and caches for advanced profile
# Reset physical build state to prevent stale Cancun artifacts from lingering
clean-advanced:
    FOUNDRY_PROFILE=advanced forge clean

# ————————————————————————————————————————————————————————————————————————————
# Tron (TronBox + local TRE) test suite
# Contracts under tron/contracts/ are GENERATED from src/ + test mocks —
# always go through the recipes below, never hand-edit them.
#
# Workflow:
#   just tre                        # once per session: start the local TRE node
#   just refresh-contracts-for-test # after editing src/ (clean regenerate + full compile)
#   just tron-test [file]           # daily loop (pure test run; refresh first after editing src/)
#
# touch-constants.js masks the "constants-only file is always dirty" profiler
# quirk. It runs ONLY in the refresh recipe — refreshing the dummy inside the
# test loop would mask a real Constants.sol change with stale bytecode.
# ————————————————————————————————————————————————————————————————————————————

# Start the local Tron runtime (TRE) on port 9090 in one terminal.
tre:
    docker run -it -p 9090:9090 --rm --name tron tronbox/tre

# Clean regenerate tron/contracts/ from the Foundry sources (the sync script
# itself does rm -rf contracts/ first), refresh the Constants.sol dummy
# artifact, then force a full compile.
# Run this after editing src/ or src-advanced/ (especially Constants.sol).
refresh-contracts-for-test:
    cd tron && node scripts/sync-contracts.js && node scripts/touch-constants.js && tronbox compile

# Run the Tron test suite against a running TRE node (see `just tre`).
# Pure test run — hits the compile cache. If you edited src/, run
# `just refresh-contracts-for-test` first or you will test stale bytecode.
# With a file argument, runs only that file: just tron-test test/PullOracleSignature.test.js
tron-test file="":
    cd tron && tronbox test {{file}}
