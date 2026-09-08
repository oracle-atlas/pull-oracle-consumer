// TronBox requires the migrations directory to exist for `tronbox test`
// (it re-runs migrations against the test network before executing suites).
//
// Every test suite deploys the contracts it needs itself via Contract.new()
// in `before` hooks, so this migration is intentionally a no-op.
module.exports = function (deployer) {};
