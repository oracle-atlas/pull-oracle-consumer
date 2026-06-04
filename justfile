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
