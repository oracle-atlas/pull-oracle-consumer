module.exports = {
  networks: {
    // Local TRE runtime (tronbox/tre docker image, see justfile `tre` target).
    development: {
      privateKey: '0000000000000000000000000000000000000000000000000000000000000001',
      userFeePercentage: 0,
      feeLimit: 1000 * 1e6,
      fullHost: 'http://127.0.0.1:9090',
      network_id: '9'
    },
    // Optional: real-network smoke test on Nile.
    nile: {
      privateKey: process.env.PRIVATE_KEY_NILE,
      userFeePercentage: 100,
      feeLimit: 1000 * 1e6,
      fullHost: 'https://nile.trongrid.io',
      network_id: '3'
    }
  },
  compilers: {
    solc: {
      // Foundry uses two profiles (0.8.13/paris for src, 0.8.24/cancun for src-advanced),
      // but the Tron suite deliberately does NOT mirror that split:
      //   - Logic correctness under BOTH solc versions is already covered by the
      //     Foundry suites (140 + 114 tests); 0.8.13 → 0.8.24 has no semantic
      //     change relevant to this codebase.
      //   - The 0.8.13/paris build exists for OLD-EVM-chain compatibility (no
      //     PUSH0/TSTORE/MCOPY) — irrelevant on Tron, where every hardfork gate
      //     is active (Shanghai/Cancun/... verified on mainnet).
      //   - The Tron suite's single job is testing the SDK in the REAL consumer
      //     environment, and consumers compile with their own TronBox config —
      //     modern setups are 0.8.24/cancun.
      // Also note: src-advanced uses tstore/tload, which solc 0.8.13 cannot
      // parse, so a 0.8.13 profile would require a separate generated tree.
      version: '0.8.24',
      settings: {
        optimizer: {
          enabled: true,
          runs: 10000
        },
        // Matches the advanced profile. TSTORE/TLOAD (src-advanced) and MCOPY are
        // supported by TRE; no viaIR — the SDK relies on hand-written assembly and
        // this keeps bytecode close to the Foundry build.
        evmVersion: 'cancun',
        metadata: {
          bytecodeHash: 'none',
          appendCBOR: false
        }
      }
    }
  }
};
