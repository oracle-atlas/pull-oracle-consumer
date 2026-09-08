// Masks TronBox's "constants-only file is always dirty" profiler quirk:
// contracts/constants/Constants.sol declares only file-level constants, so it
// never produces a build artifact, and the profiler then pulls its whole
// import graph into a full recompile on every run. A dummy artifact with a
// fresh updatedAt short-circuits that check.
//
// Run ONLY from the refresh recipe — refreshing the dummy in the test loop
// would mask a real Constants.sol change and leave importers on stale bytecode.
const fs = require('fs');
const path = require('path');

const artifactDir = path.join(__dirname, '..', 'build', 'contracts');
const artifactPath = path.join(artifactDir, 'Constants.json');

const artifact = {
  contractName: 'Constants',
  sourcePath: path.join(__dirname, '..', 'contracts', 'constants', 'Constants.sol'),
  updatedAt: new Date().toISOString(),
  schemaVersion: '3.4.15',
};

fs.mkdirSync(artifactDir, { recursive: true });
fs.writeFileSync(artifactPath, JSON.stringify(artifact, null, 2) + '\n');
console.log(`Refreshed ${artifactPath}`);
