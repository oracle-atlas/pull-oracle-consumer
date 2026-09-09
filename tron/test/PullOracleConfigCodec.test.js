// TronBox test for PullOracleConfigCodec — port of test/unit/PullOracleConfigCodec.t.sol.
// All calls run as constant (pure) calls on the real TVM.
//
// Omitted from the Foundry original:
//   - test_PackConfig_UpperBitsZeroed_Fuzz / test_ExtractTimestampThresholds_
//     Consistency_Fuzz / test_Roundtrip_Fuzz / test_Isolation_*_Fuzz /
//     test_UpdateIdempotent_Fuzz / test_SequentialMutation_Fuzz: fuzz stays in
//     Foundry; each has a concrete stand-in below with bit-pattern-sensitive
//     values.
//   - test_Update{MaxPackageCount,MaxDelay,MaxFutureDrift}_Fuzz: covered by the
//     concrete mutation cases + roundtrip + sequential-mutation stand-ins.
//
// Config word layout (right-aligned, 104 bits): count<<96 | delay<<48 | drift.

const PullOracleConfigCodecMock = artifacts.require('PullOracleConfigCodecMock');
const { expect } = require('chai');
const {
  encodeCallData,
  expectConstantSuccess,
  callConstantRaw,
  setBalance,
} = require('../test-utils');

// Concrete triples (mirrors Foundry) + a bit-pattern-sensitive stand-in triple
// for the fuzz cases: every field carries high bits to catch mask/shift bugs.
const COUNT = 10n;
const DELAY = 60n;
const DRIFT = 30n;
const MAX_COUNT = 255n;
const MAX_DELAY = (1n << 48n) - 1n;
const MAX_DRIFT = (1n << 48n) - 1n;
const STAND_COUNT = 200n;
const STAND_DELAY = 0x123456789abn;
const STAND_DRIFT = 0xfedcba98765n; // fits uint48

// Expected packing, mirroring the Foundry asserts:
// count at bits [103:96], delay at [95:48], drift at [47:0], upper bits zero.
const expectedWord = (count, delay, drift) =>
  (BigInt(count) << 96n) | (BigInt(delay) << 48n) | BigInt(drift);
// bytes32 argument form (0x + 64 hex chars).
const hex32 = (word) => '0x' + word.toString(16).padStart(64, '0');

contract('PullOracleConfigCodec', function (accounts) {
  let mock;

  before(async function () {
    await setBalance(accounts[0], 10000000);
    mock = await PullOracleConfigCodecMock.new({ from: accounts[0] });
  });

  const run = (input) => callConstantRaw(mock.address, input, accounts[0]);
  const call1 = async (sig, args) => expectConstantSuccess(await run(encodeCallData(sig, args)));

  async function pack(count, delay, drift) {
    const [word] = await call1('packConfig(uint8,uint48,uint48)', [count, delay, drift]);
    return word;
  }

  describe('packConfig', function () {
    // test_PackConfig_ConcreteValues
    it('packs concrete values into the documented bit layout', async function () {
      const word = await pack(COUNT, DELAY, DRIFT);
      expect(word).to.equal(expectedWord(COUNT, DELAY, DRIFT));
    });

    // test_PackConfig_MaxBoundary
    it('packs maximum boundary values for all three fields', async function () {
      const word = await pack(MAX_COUNT, MAX_DELAY, MAX_DRIFT);
      expect(word).to.equal(expectedWord(MAX_COUNT, MAX_DELAY, MAX_DRIFT));
    });

    // test_PackConfig_AllZeros
    it('packs all-zero fields to an empty word', async function () {
      const word = await pack(0, 0, 0);
      expect(word).to.equal(0n);
    });

    // Concrete stand-in for test_PackConfig_UpperBitsZeroed_Fuzz: bits
    // [255:104] must stay zeroed for arbitrary field values.
    it('keeps bits above 104 zeroed for the stand-in triple', async function () {
      const word = await pack(STAND_COUNT, STAND_DELAY, STAND_DRIFT);
      expect(word >> 104n).to.equal(0n);
      expect(word).to.equal(expectedWord(STAND_COUNT, STAND_DELAY, STAND_DRIFT));
    });
  });

  describe('extract', function () {
    // test_Extract_ConcreteValues
    it('extracts each field with concrete values', async function () {
      const config = hex32(expectedWord(COUNT, DELAY, DRIFT));
      expect(await call1('extractMaxPackageCount(bytes32)', [config])).to.deep.equal([COUNT]);
      expect(await call1('extractMaxDelay(bytes32)', [config])).to.deep.equal([DELAY]);
      expect(await call1('extractMaxFutureDrift(bytes32)', [config])).to.deep.equal([DRIFT]);
    });

    // test_Extract_MaxBoundary
    it('extracts each field at maximum boundary values', async function () {
      const config = hex32(expectedWord(MAX_COUNT, MAX_DELAY, MAX_DRIFT));
      expect(await call1('extractMaxPackageCount(bytes32)', [config])).to.deep.equal([MAX_COUNT]);
      expect(await call1('extractMaxDelay(bytes32)', [config])).to.deep.equal([MAX_DELAY]);
      expect(await call1('extractMaxFutureDrift(bytes32)', [config])).to.deep.equal([MAX_DRIFT]);
    });

    // Concrete stand-in for test_ExtractTimestampThresholds_Consistency_Fuzz:
    // the combined extractor must agree with the individual ones.
    it('extractTimestampThresholds matches the individual extractors', async function () {
      const config = hex32(expectedWord(STAND_COUNT, STAND_DELAY, STAND_DRIFT));
      const [combinedDelay, combinedDrift] = await call1('extractTimestampThresholds(bytes32)', [config]);
      const [delay] = await call1('extractMaxDelay(bytes32)', [config]);
      const [drift] = await call1('extractMaxFutureDrift(bytes32)', [config]);
      expect(combinedDelay).to.equal(delay);
      expect(combinedDrift).to.equal(drift);
    });
  });

  describe('roundtrip', function () {
    // Concrete stand-in for test_Roundtrip_Fuzz: pack → extract is lossless.
    it('roundtrips the stand-in triple losslessly', async function () {
      const config = await pack(STAND_COUNT, STAND_DELAY, STAND_DRIFT);
      const configHex = hex32(config);
      expect(await call1('extractMaxPackageCount(bytes32)', [configHex])).to.deep.equal([STAND_COUNT]);
      expect(await call1('extractMaxDelay(bytes32)', [configHex])).to.deep.equal([STAND_DELAY]);
      expect(await call1('extractMaxFutureDrift(bytes32)', [configHex])).to.deep.equal([STAND_DRIFT]);
    });
  });

  describe('field isolation', function () {
    // Concrete stand-ins for the three test_Isolation_*_Fuzz cases.
    it('keeps other fields zeroed when only maxPackageCount is set', async function () {
      const config = await pack(STAND_COUNT, 0, 0);
      const configHex = hex32(config);
      expect(await call1('extractMaxPackageCount(bytes32)', [configHex])).to.deep.equal([STAND_COUNT]);
      expect(await call1('extractMaxDelay(bytes32)', [configHex])).to.deep.equal([0n]);
      expect(await call1('extractMaxFutureDrift(bytes32)', [configHex])).to.deep.equal([0n]);
    });

    it('keeps other fields zeroed when only maxDelay is set', async function () {
      const config = await pack(0, STAND_DELAY, 0);
      const configHex = hex32(config);
      expect(await call1('extractMaxPackageCount(bytes32)', [configHex])).to.deep.equal([0n]);
      expect(await call1('extractMaxDelay(bytes32)', [configHex])).to.deep.equal([STAND_DELAY]);
      expect(await call1('extractMaxFutureDrift(bytes32)', [configHex])).to.deep.equal([0n]);
    });

    it('keeps other fields zeroed when only maxFutureDrift is set', async function () {
      const config = await pack(0, 0, STAND_DRIFT);
      const configHex = hex32(config);
      expect(await call1('extractMaxPackageCount(bytes32)', [configHex])).to.deep.equal([0n]);
      expect(await call1('extractMaxDelay(bytes32)', [configHex])).to.deep.equal([0n]);
      expect(await call1('extractMaxFutureDrift(bytes32)', [configHex])).to.deep.equal([STAND_DRIFT]);
    });
  });

  describe('mutation', function () {
    // test_UpdateMaxPackageCount_Concrete
    it('updates maxPackageCount and returns the previous value', async function () {
      const config = hex32(expectedWord(COUNT, DELAY, DRIFT));
      const [newConfig, oldValue] = await call1('updateMaxPackageCount(bytes32,uint8)', [config, 20]);
      expect(oldValue).to.equal(COUNT);
      expect(newConfig).to.equal(expectedWord(20, DELAY, DRIFT));
    });

    // test_UpdateMaxDelay_Concrete
    it('updates maxDelay and returns the previous value', async function () {
      const config = hex32(expectedWord(COUNT, DELAY, DRIFT));
      const [newConfig, oldValue] = await call1('updateMaxDelay(bytes32,uint48)', [config, 300]);
      expect(oldValue).to.equal(DELAY);
      expect(newConfig).to.equal(expectedWord(COUNT, 300, DRIFT));
    });

    // test_UpdateMaxFutureDrift_Concrete
    it('updates maxFutureDrift and returns the previous value', async function () {
      const config = hex32(expectedWord(COUNT, DELAY, DRIFT));
      const [newConfig, oldValue] = await call1('updateMaxFutureDrift(bytes32,uint48)', [config, 120]);
      expect(oldValue).to.equal(DRIFT);
      expect(newConfig).to.equal(expectedWord(COUNT, DELAY, 120));
    });

    // Concrete stand-in for test_UpdateIdempotent_Fuzz: updating a field to
    // its current value leaves the word untouched.
    it('is idempotent when updating to the current value', async function () {
      const config = expectedWord(STAND_COUNT, STAND_DELAY, STAND_DRIFT);
      const configHex = hex32(config);
      const [afterCount] = await call1('updateMaxPackageCount(bytes32,uint8)', [configHex, STAND_COUNT]);
      expect(afterCount).to.equal(config);
      const [afterDelay] = await call1('updateMaxDelay(bytes32,uint48)', [configHex, STAND_DELAY]);
      expect(afterDelay).to.equal(config);
      const [afterDrift] = await call1('updateMaxFutureDrift(bytes32,uint48)', [configHex, STAND_DRIFT]);
      expect(afterDrift).to.equal(config);
    });

    // Concrete stand-in for test_SequentialMutation_Fuzz: chaining all three
    // mutations equals a fresh pack with the final values.
    it('matches a fresh pack after chained mutations', async function () {
      const initial = await pack(1, 2, 3);
      const [afterCount] = await call1('updateMaxPackageCount(bytes32,uint8)', [hex32(initial), STAND_COUNT]);
      const [afterDelay] = await call1('updateMaxDelay(bytes32,uint48)', [hex32(afterCount), STAND_DELAY]);
      const [afterDrift] = await call1('updateMaxFutureDrift(bytes32,uint48)', [hex32(afterDelay), STAND_DRIFT]);
      expect(afterDrift).to.equal(expectedWord(STAND_COUNT, STAND_DELAY, STAND_DRIFT));
    });
  });
});
