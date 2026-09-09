// TronBox test for PullOracleSignature — port of test/unit/PullOracleSignature.t.sol.
// All calls run as constant (view) calls: TVM exercises the real ecrecover
// precompile with no broadcast needed.
//
// Omitted from the Foundry original:
//   - test_RecoverSigner_Fuzz: fuzz stays in Foundry; concrete counts 1/3/255 below.
//   - test_EcrecoverPrecompile_InvalidV_ReturnsEmptyData: EVM scratch-space
//     semantics, not observable via TVM constant calls; the load-bearing
//     behavior (empty ecrecover return → revert) is covered by the v/r cases.

const PullOracleSignatureMock = artifacts.require('PullOracleSignatureMock');
const { expect } = require('chai');
const ethers = require('ethers');
const {
  wordToAddress,
  encodeCallData,
  writeWord,
  signDigest,
  expectConstantSuccess,
  expectConstantRevert,
  callConstantRaw,
  setBalance,
  MAGIC_MARKER,
  MAX_LOW_S_VALUE,
  PRIMARY_SIGNER_PK,
  PRIMARY_SIGNER,
} = require('../test-utils');

// secp256k1 curve order n (invalid r values: 0 and n).
const CURVE_ORDER_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;

// Calldata offsets from the END:
//   [selector 4B][payloadStart 32B][payloadEnd 32B][packages 20B×N][count 1B][r 32B][s 32B][v 1B][marker 2B]
const S_OFFSET_FROM_END = 35; // marker(2) + v(1) + s(32)
const R_OFFSET_FROM_END = 67; // marker(2) + v(1) + s(32) + r(32)
const V_OFFSET_FROM_END = 3;  // marker(2) + v(1)

contract('PullOracleSignature', function (accounts) {
  let mock;

  before(async function () {
    await setBalance(accounts[0], 10000000);
    mock = await PullOracleSignatureMock.new({ from: accounts[0] });
  });

  // Port of BaseTest._prepareRecoverSignerCall: full calldata for
  // recoverSigner(uint256,uint256) with N 20-byte packages,
  // signed over keccak256([packages][count]). Packages start at byte 68.
  function buildRecoverSignerInput(signerPk, count) {
    const payloadStart = 68;
    const payloadEnd = payloadStart + count * 20;
    const head = ethers.getBytes(encodeCallData('recoverSigner(uint256,uint256)', [payloadStart, payloadEnd]));

    const packages = [];
    for (let i = 0; i < count; i++) {
      packages.push(ethers.getBytes(ethers.keccak256(ethers.toUtf8Bytes('mockPackage' + i))).slice(0, 20));
    }
    const packagesBytes = ethers.concat(packages);
    const countBytes = new Uint8Array([count]);
    const digest = ethers.keccak256(ethers.concat([packagesBytes, countBytes]));
    const sig = signDigest(signerPk, digest);
    // Marker bytes derived from the protocol constant — no duplicated literal.
    const marker = new Uint8Array([MAGIC_MARKER >> 8, MAGIC_MARKER & 0xff]);

    // NOTE: ethers 6.17's concat() returns a 0x-prefixed hex STRING, not
    // Uint8Array — wrap with getBytes so byte writes below operate on bytes.
    return ethers.getBytes(ethers.concat([head, packagesBytes, countBytes, sig, marker]));
  }

  async function runRecoverSigner(input) {
    return callConstantRaw(mock.address, '0x' + Buffer.from(input).toString('hex'), accounts[0]);
  }

  describe('happy path', function () {
    // test_RecoverSigner_Success
    it('recovers the authorized signer from a valid 3-package payload', async function () {
      const words = expectConstantSuccess(await runRecoverSigner(buildRecoverSignerInput(PRIMARY_SIGNER_PK, 3)));
      expect(wordToAddress(words[0]).toLowerCase()).to.equal(PRIMARY_SIGNER.toLowerCase());
    });

    // test_RecoverSigner_TamperedData_ReturnsWrongAddress: flip package byte 0.
    it('returns a wrong signer when a single package byte is tampered', async function () {
      const input = buildRecoverSignerInput(PRIMARY_SIGNER_PK, 1);
      input[68] ^= 0xff;
      const words = expectConstantSuccess(await runRecoverSigner(input));
      expect(wordToAddress(words[0]).toLowerCase()).to.not.equal(PRIMARY_SIGNER.toLowerCase());
    });

    // Stand-in for the omitted fuzz's upper bound: pointer arithmetic at scale.
    it('recovers the authorized signer from a uint8-max (255) package payload', async function () {
      const words = expectConstantSuccess(await runRecoverSigner(buildRecoverSignerInput(PRIMARY_SIGNER_PK, 255)));
      expect(wordToAddress(words[0]).toLowerCase()).to.equal(PRIMARY_SIGNER.toLowerCase());
    });
  });

  describe('negative cases', function () {
    // test_Revert_InvalidSignatureS: s = MAX_LOW_S + 1 fails the EIP-2 check.
    it('reverts InvalidSignatureS when s exceeds the low-S bound', async function () {
      const input = buildRecoverSignerInput(PRIMARY_SIGNER_PK, 1);
      writeWord(input, input.length - S_OFFSET_FROM_END, MAX_LOW_S_VALUE + 1n);
      expectConstantRevert(await runRecoverSigner(input), 'InvalidSignatureS()');
    });

    // test_RecoverSigner_InvalidV_Revert_SignatureRecoveryFailed.
    it('reverts SignatureRecoveryFailed when v is neither 27 nor 28', async function () {
      const input = buildRecoverSignerInput(PRIMARY_SIGNER_PK, 1);
      input[input.length - V_OFFSET_FROM_END] = 27 - 1;
      expectConstantRevert(await runRecoverSigner(input), 'SignatureRecoveryFailed()');
    });

    // test_RecoverSigner_InvalidR_Revert_SignatureRecoveryFailed: ecrecover
    // returns empty data for r = 0 or r >= n → the consumer must revert.
    it('reverts SignatureRecoveryFailed when r is the curve order or zero', async function () {
      let input = buildRecoverSignerInput(PRIMARY_SIGNER_PK, 1);
      writeWord(input, input.length - R_OFFSET_FROM_END, CURVE_ORDER_N);
      expectConstantRevert(await runRecoverSigner(input), 'SignatureRecoveryFailed()');

      input = buildRecoverSignerInput(PRIMARY_SIGNER_PK, 1);
      writeWord(input, input.length - R_OFFSET_FROM_END, 0);
      expectConstantRevert(await runRecoverSigner(input), 'SignatureRecoveryFailed()');
    });
  });
});
