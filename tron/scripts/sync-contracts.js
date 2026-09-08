#!/usr/bin/env node
// Regenerates tron/contracts/ from the Foundry sources — rm -rf first, so the
// tree is always clean and deterministic. Run via `just refresh-contracts-for-test`.
//
//   src/**                 → contracts/**          (flattened to the root)
//   src-advanced/*.sol     → contracts/*.sol
//   test/mocks/**          → contracts/mocks/**
//   test/advanced/mocks/** → contracts/mocks/**
//
// Imports: TronBox resolves only relative paths — a bare "pkg/X.sol" import
// fails with `Package "pkg" is not installed`. Every non-relative import is
// rewritten to a path relative to the importing file's directory:
//   contracts/base/F.sol:   "constants/Constants.sol" → "../constants/Constants.sol"
//   contracts/F.sol:        "base/X.sol"              → "./base/X.sol"
//   contracts/mocks/F.sol:  "src/base/X.sol"          → "../base/X.sol"
//                           "src-advanced/X.sol"      → "../X.sol"
//
// NOTE: `just tron-test` does NOT run this script — a fresh tree forces a full
// recompile. After editing src/, run `just refresh-contracts-for-test` first.

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const DEST = path.resolve(__dirname, '..', 'contracts');

// [sourceDir (relative to repo root), destDir (relative to contracts/)]
const COPY_MAP = [
  ['src', '.'],
  ['src-advanced', '.'],
  ['test/mocks', 'mocks'],
  ['test/advanced/mocks', 'mocks'],
];

// Bare → relative to the importing file; strips "src/" / "src-advanced/".
function rewriteImportPath(importPath, fromDir) {
  if (importPath.startsWith('./') || importPath.startsWith('../')) return importPath;

  const target = importPath.replace(/^src-advanced\//, '').replace(/^src\//, '');
  let rel = path.posix.relative(fromDir, target);
  if (!rel.startsWith('.')) rel = './' + rel;
  return rel;
}

function rewriteImports(text, destRelPath) {
  const fromDir = path.posix.dirname(destRelPath);
  // Covers `import {A} from "X";` — the only import form used by these sources.
  return text.replace(/(from\s+")([^"]+)(")/g, (match, pre, importPath, post) => {
    const rewritten = rewriteImportPath(importPath, fromDir);
    return rewritten === importPath ? match : pre + rewritten + post;
  });
}

function copySolDir(srcAbs, destAbs, destRelBase) {
  fs.mkdirSync(destAbs, { recursive: true });
  for (const entry of fs.readdirSync(srcAbs, { withFileTypes: true })) {
    const from = path.join(srcAbs, entry.name);
    const to = path.join(destAbs, entry.name);
    if (entry.isDirectory()) {
      copySolDir(from, to, path.posix.join(destRelBase, entry.name));
    } else if (entry.name.endsWith('.sol')) {
      const destRelPath = path.posix.join(destRelBase, entry.name);
      const text = rewriteImports(fs.readFileSync(from, 'utf8'), destRelPath);
      fs.writeFileSync(to, text);
    }
  }
}

function main() {
  fs.rmSync(DEST, { recursive: true, force: true });
  fs.mkdirSync(DEST, { recursive: true });

  const copied = [];
  for (const [srcRel, destRel] of COPY_MAP) {
    const srcAbs = path.join(REPO_ROOT, srcRel);
    if (!fs.existsSync(srcAbs)) {
      throw new Error(`source directory not found: ${srcAbs}`);
    }
    copySolDir(srcAbs, path.join(DEST, destRel), destRel === '.' ? '' : destRel);
    copied.push(`${srcRel}/ → contracts/${destRel === '.' ? '' : destRel}`);
  }

  console.log('tron/contracts/ regenerated (clean rebuild, imports rewritten to relative paths):');
  copied.forEach((line) => console.log(`  ${line}`));
}

main();
