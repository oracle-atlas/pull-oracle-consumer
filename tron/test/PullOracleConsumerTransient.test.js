// TronBox test for PullOracleConsumerTransient — port of
// test/advanced/unit/PullOracleConsumerTransient.t.sol (30 cases, 1:1).
//
// EXECUTION MODEL: every case is a constant call. The transient-cache probes
// run TSTORE under wallet/triggerconstantcontract — TVM discards the effects
// but the return data / revert data still exercise the logic under test.
//
// TRANSIENT-LIFETIME PORTING NOTE (TVM vs Foundry): transient storage lives
// for one transaction, and each TRE constant call IS one transaction. The
// Foundry suite proves cross-CALL persistence with two separate mock calls
// per test (cache in call 1, read in call 2, same tx) — impossible across
// two constant calls. Three cases therefore run through TVM-only merged
// probes on the mock that open the second call frame from inside one
// constant call:
//   - cacheLeakProbeForTest    cache, then read from a nested sub-call frame
//   - cacheClearProbeForTest   cache + clear, then read from a nested frame
//   - cacheForeignPoisonProbeForTest  cache, then a SECOND contract TSTOREs
//     its own slots under the same keys, then read own slots (an EOA cannot
//     TSTORE; EIP-1153 slot scoping is per-address and symmetric, so the
//     writer-as-callee shape covers the same guarantee Foundry's caller-side
//     TSTORE demonstrates).
//
// TIMESTAMP STRATEGY: constant calls execute on the SAME block that
// currentSeconds() reads (TRE mines on demand), so Foundry-exact offsets
// (-181 stale / +61 drift) apply directly, no landing margin needed.

const ConsumerTransientTvmMock = artifacts.require('ConsumerTransientTvmMock');
const TransientSlotWriter = artifacts.require('TransientSlotWriter');
const { expect } = require('chai');
const ethers = require('ethers');
const {
  buildUnsignedExtraData,
  buildSignedExtraData,
  encodeCallData,
  constantResultHex,
  expectConstantSuccess,
  expectConstantRevert,
  expectRevertArgs,
  callConstantRaw,
  decodeTwoUint256Arrays,
  dummyId,
  setBalance,
  currentSeconds,
  toHex,
  FEED_PACKAGE_SIZE,
  SECONDARY_SIGNER_PK,
} = require('../test-utils');

const E18 = 10n ** 18n;
const TARGET_ID = '0x11223344';
const TARGET_PRICE = 50000n * E18;
const OTHER_ID = '0x99999999';

// Top-160-bit mask of the physical package layout: [ID 4B | Price 10B | Timestamp 6B].
const HIGH_20_MASK = (1n << 256n) - (1n << 96n);

// Physical package word: [ID << 224 | Price << 144 | Timestamp << 96].
const leftAlignedPackage = (id, price, ts) =>
  (BigInt(id) << 224n) | (BigInt(price) << 144n) | (BigInt(ts) << 96n);

// Foreign transient word carrying feed ID 0xEEEEEEEE in the high 4 bytes.
const foreignWord = (now) =>
  ethers.toBeHex((0xeeeeeeeen << 224n) | (999n * E18 << 144n) | (now << 96n), 32);

contract('PullOracleConsumerTransient', function (accounts) {
  let mock;
  let poisoner;

  before(async function () {
    await setBalance(accounts[0], 10000000);
    mock = await ConsumerTransientTvmMock.new({ from: accounts[0] });
    poisoner = await TransientSlotWriter.new({ from: accounts[0] });
  });

  // Constant call with trailing oracle extraData (relay-style calldata append).
  const run = (sig, args, extraData) =>
    callConstantRaw(mock.address, encodeCallData(sig, args) + (extraData ? extraData.slice(2) : ''), accounts[0]);

  // Two-pass payload offset: encode a probe with the SAME argument shape but
  // placeholder offset values — the head length does not depend on the offset
  // VALUE — then use its byte length as payloadStart (the position where the
  // appended extraData begins inside the combined calldata).
  const payloadStartOf = (sig, probeArgs) => ethers.getBytes(encodeCallData(sig, probeArgs)).length;

  // Decode a bytes32[] return into BigInt words.
  const wordArrayReturn = (res) => {
    const words = expectConstantSuccess(res);
    const off = Number(words[0]) / 32;
    const len = Number(words[off]);
    return words.slice(off + 1, off + 1 + len);
  };

  // Decode a (bytes32[], bytes32[]) return.
  const twoWordArrayReturn = (res) => {
    const words = expectConstantSuccess(res);
    const out = [];
    for (let k = 0; k < 2; k++) {
      const idx = Number(words[k]) / 32;
      const len = Number(words[idx]);
      out.push(words.slice(idx + 1, idx + 1 + len));
    }
    return out;
  };

  // Decode a (uint256[], uint256[]) return after asserting call success.
  const twoUint256Return = (res) => {
    expectConstantSuccess(res);
    return decodeTwoUint256Arrays(constantResultHex(res));
  };

  /* ————————————————————————————————————————————————————————————————————————
                        TRANSIENT CACHE: WRITE & ALIGNMENT
  ———————————————————————————————————————————————————————————————————————— */

  // test_cacheFeedPackagesToTransientStorage_PhysicalAlignment
  it('caches packages with the documented left-aligned physical layout', async function () {
    const now = await currentSeconds();
    const count = 5;
    const ids = [dummyId(0), dummyId(1), dummyId(2), dummyId(3), dummyId(4)];
    const prices = [100n * E18, 200n * E18, 300n * E18, 400n * E18, 500n * E18];
    const timestamps = [now, now - 1n, now - 2n, now - 3n, now - 4n];
    const extraData = buildUnsignedExtraData(ids, prices, timestamps);

    const payloadStart = payloadStartOf('cacheAndReadBackForTest(bytes4[],uint256,uint256)', [ids, 0, count]);
    const words = wordArrayReturn(await run('cacheAndReadBackForTest(bytes4[],uint256,uint256)', [ids, payloadStart, count], extraData));

    for (let i = 0; i < count; i++) {
      expect(words[i] & HIGH_20_MASK, `high 160-bit mismatch at package index ${i}`).to.equal(
        leftAlignedPackage(ids[i], prices[i], timestamps[i])
      );
    }
  });

  // test_cacheFeedPackagesToTransientStorage_LIFO_Overwrite
  it('overwrites duplicate IDs LIFO: the last physical package prevails', async function () {
    const now = await currentSeconds();
    const ids = [TARGET_ID, OTHER_ID, TARGET_ID];
    const prices = [TARGET_PRICE - 2n, TARGET_PRICE - 1n, TARGET_PRICE];
    const timestamps = [now, now, now + 1n];
    const checkIds = [TARGET_ID, OTHER_ID];
    const extraData = buildUnsignedExtraData(ids, prices, timestamps);

    const payloadStart = payloadStartOf('cacheAndReadBackForTest(bytes4[],uint256,uint256)', [checkIds, 0, 3]);
    const words = wordArrayReturn(await run('cacheAndReadBackForTest(bytes4[],uint256,uint256)', [checkIds, payloadStart, 3], extraData));

    // Target ID slot must hold the LAST package; the other ID must be intact.
    expect(words[0] & HIGH_20_MASK, 'Target ID slot was not overwritten by the last package').to.equal(
      leftAlignedPackage(TARGET_ID, TARGET_PRICE, now + 1n)
    );
    expect(words[1] & HIGH_20_MASK, 'Other ID slot was corrupted during target overwrite').to.equal(
      leftAlignedPackage(OTHER_ID, TARGET_PRICE - 1n, now)
    );
  });

  /* ————————————————————————————————————————————————————————————————————————
                        TRANSIENT CACHE: CLEAR VERIFICATION
  ———————————————————————————————————————————————————————————————————————— */

  // test_clearTransientCache_ZerosAllCachedSlots
  it('zeros every cached slot after the clear (before/after reads in one frame)', async function () {
    const now = await currentSeconds();
    const count = 3;
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now, now];
    const extraData = buildUnsignedExtraData(ids, prices, timestamps);

    const payloadStart = payloadStartOf('cacheReadClearReadForTest(bytes4[],uint256,uint256)', [ids, 0, count]);
    const [before, after] = twoWordArrayReturn(
      await run('cacheReadClearReadForTest(bytes4[],uint256,uint256)', [ids, payloadStart, count], extraData)
    );

    for (let i = 0; i < count; i++) {
      expect(before[i] & HIGH_20_MASK, 'Pre-clear: slot must contain cached package data').to.equal(
        leftAlignedPackage(ids[i], prices[i], timestamps[i])
      );
      expect(after[i], 'Post-clear: slot must be fully zeroed').to.equal(0n);
    }
  });

  // test_clearTransientCache_WithoutClear_SlotsLeakAcrossCalls
  // Port note: Foundry caches and cross-frame-reads via two mock calls inside
  // one tx; each TRE constant call is its own transaction (transient storage
  // dies with it), so both steps are merged into cacheLeakProbeForTest — the
  // read runs in a nested sub-call frame.
  it('keeps stale slots readable from a later call frame when no clear is performed', async function () {
    const now = await currentSeconds();
    const count = 3;
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now, now];
    const extraData = buildUnsignedExtraData(ids, prices, timestamps);

    const payloadStart = payloadStartOf('cacheLeakProbeForTest(bytes4[],uint256,uint256)', [ids, 0, count]);
    const words = wordArrayReturn(await run('cacheLeakProbeForTest(bytes4[],uint256,uint256)', [ids, payloadStart, count], extraData));

    for (let i = 0; i < count; i++) {
      expect(
        words[i] & HIGH_20_MASK,
        'Stale slot must still be readable across call frames when no clear is performed'
      ).to.equal(leftAlignedPackage(ids[i], prices[i], timestamps[i]));
    }
  });

  // test_clearTransientCache_PreventsCrossCallContamination
  it('leaves no residual data observable from a later call frame after a complete invocation', async function () {
    const now = await currentSeconds();
    const count = 3;
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now, now];
    const extraData = buildUnsignedExtraData(ids, prices, timestamps);

    const payloadStart = payloadStartOf('cacheClearProbeForTest(bytes4[],uint256,uint256)', [ids, 0, count]);
    const words = wordArrayReturn(await run('cacheClearProbeForTest(bytes4[],uint256,uint256)', [ids, payloadStart, count], extraData));

    for (let i = 0; i < count; i++) {
      expect(words[i], 'Slot must be zero after clear: no cross-call contamination').to.equal(0n);
    }
  });

  // test_clearTransientCache_CallerTstoreDoesNotAffectCalleeSlots
  // Port note: Foundry TSTOREs from the caller; on TRE the caller is an EOA
  // and cannot TSTORE, so the mock caches, has TransientSlotWriter poison
  // ITS OWN slots under the same keys, then reads its own slots back.
  // EIP-1153 slot keys are per-address, so the guarantee holds regardless
  // of which contract performs the foreign write.
  it('keeps the mock transient slots unaffected by a foreign contract TSTORE', async function () {
    const now = await currentSeconds();
    const count = 3;
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now, now];
    const extraData = buildUnsignedExtraData(ids, prices, timestamps);
    const poisonerEvm = '0x' + toHex(poisoner.address).slice(2);

    const payloadStart = payloadStartOf('cacheForeignPoisonProbeForTest(bytes4[],uint256,uint256,address)', [ids, 0, count, ethers.ZeroAddress]);
    const words = wordArrayReturn(
      await run('cacheForeignPoisonProbeForTest(bytes4[],uint256,uint256,address)', [ids, payloadStart, count, poisonerEvm], extraData)
    );

    for (let i = 0; i < count; i++) {
      expect(words[i] & HIGH_20_MASK, "Mock's transient slot must be unaffected by the foreign TSTORE").to.equal(
        leftAlignedPackage(ids[i], prices[i], timestamps[i])
      );
    }
  });

  /* ————————————————————————————————————————————————————————————————————————
                        STRICT MODE (TRANSIENT): BATCH SEARCH
  ———————————————————————————————————————————————————————————————————————— */

  // test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient_Success
  it('strict batch search returns requested values in order across an unordered payload', async function () {
    const now = await currentSeconds();
    const requestedIds = ['0x11111111', '0x22222222', '0x33333333'];
    const payloadIds = [
      requestedIds[0],
      dummyId(1),
      requestedIds[1],
      dummyId(3),
      requestedIds[2],
    ];
    const payloadPrices = [100n * E18, 50n * E18, 200n * E18, 50n * E18, 300n * E18];
    const payloadTimestamps = [now, now - 1n, now - 2n, now - 3n, now - 4n];

    const payloadStart = payloadStartOf('getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 5 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    const [prices, ts] = twoUint256Return(
      await run('getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, payloadStart, payloadEnd], extraData)
    );

    expect(prices).to.deep.equal([100n * E18, 200n * E18, 300n * E18]);
    expect(ts).to.deep.equal([now, now - 2n, now - 4n]);
  });

  // test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient_Revert_PartialUnmatchedID
  it('strict batch search reverts UnmatchedFeedID when one requested ID is absent', async function () {
    const now = await currentSeconds();
    const requestedIds = ['0x11111111', '0xdeadbeef', '0x33333333'];
    const payloadIds = [requestedIds[0], dummyId(1), dummyId(2), dummyId(3), requestedIds[2]];
    const payloadPrices = Array(5).fill(100n * E18);
    const payloadTimestamps = Array(5).fill(now);

    const payloadStart = payloadStartOf('getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 5 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    expectConstantRevert(
      await run('getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, payloadStart, payloadEnd], extraData),
      'UnmatchedFeedID(bytes4)',
      [BigInt('0xdeadbeef') << 224n]
    );
  });

  // test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient_Revert_PartialExpired
  it('strict batch search reverts PriceFeedExpired for the one expired ID in the batch', async function () {
    const now = await currentSeconds();
    const expiredTs = now - 181n;
    const requestedIds = ['0x11111111', '0x22222222', '0x33333333'];
    const payloadIds = [requestedIds[0], dummyId(1), requestedIds[1], dummyId(3), requestedIds[2]];
    const payloadPrices = Array(5).fill(100n * E18);
    const payloadTimestamps = [now, now, now, now, expiredTs];

    const payloadStart = payloadStartOf('getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 5 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    const words = expectRevertArgs(
      await run('getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, payloadStart, payloadEnd], extraData),
      'PriceFeedExpired(bytes4,uint256,uint256)'
    );
    expect(words[0] >> 224n).to.equal(BigInt(requestedIds[2]));
    expect(words[1]).to.equal(expiredTs);
    expect(words[2]).to.equal(now);
  });

  // test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient_Revert_PartialFutureDrift
  it('strict batch search reverts PriceFeedFutureDrift for one drifting ID', async function () {
    const now = await currentSeconds();
    const futureTs = now + 61n;
    const requestedIds = ['0x11111111', '0x22222222', '0x33333333'];
    const payloadIds = [requestedIds[0], dummyId(1), requestedIds[1], dummyId(3), requestedIds[2]];
    const payloadPrices = Array(5).fill(100n * E18);
    const payloadTimestamps = [now, now, futureTs, now, now];

    const payloadStart = payloadStartOf('getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 5 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    const words = expectRevertArgs(
      await run('getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, payloadStart, payloadEnd], extraData),
      'PriceFeedFutureDrift(bytes4,uint256,uint256)'
    );
    expect(words[0] >> 224n).to.equal(BigInt(requestedIds[1]));
    expect(words[1]).to.equal(futureTs);
    expect(words[2]).to.equal(now);
  });

  /* ————————————————————————————————————————————————————————————————————————
                        LENIENT MODE (TRANSIENT): BATCH SEARCH
  ———————————————————————————————————————————————————————————————————————— */

  // test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient_Success_PartialMissing
  it('lenient batch search returns zeros for missing IDs instead of reverting', async function () {
    const now = await currentSeconds();
    const requestedIds = ['0x11111111', '0xdeadbeef', '0x33333333'];
    const payloadIds = [requestedIds[0], dummyId(1), dummyId(2), dummyId(3), requestedIds[2]];
    const payloadPrices = [100n * E18, 50n * E18, 50n * E18, 50n * E18, 300n * E18];
    const payloadTimestamps = Array(5).fill(now);

    const payloadStart = payloadStartOf('getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 5 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    const [prices, ts] = twoUint256Return(
      await run('getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, payloadStart, payloadEnd], extraData)
    );

    expect(prices).to.deep.equal([100n * E18, 0n, 300n * E18]);
    expect(ts).to.deep.equal([now, 0n, now]);
  });

  // test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient_Success_AllMissing
  it('lenient batch search returns all zeros when nothing matches', async function () {
    const now = await currentSeconds();
    const requestedIds = ['0xaaaaaaaa', '0xbbbbbbbb', '0xcccccccc'];
    const payloadIds = [dummyId(0), dummyId(1), dummyId(2), dummyId(3), dummyId(4)];
    const payloadPrices = Array(5).fill(100n * E18);
    const payloadTimestamps = Array(5).fill(now);

    const payloadStart = payloadStartOf('getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 5 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    const [prices, ts] = twoUint256Return(
      await run('getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, payloadStart, payloadEnd], extraData)
    );

    expect(prices).to.deep.equal([0n, 0n, 0n]);
    expect(ts).to.deep.equal([0n, 0n, 0n]);
  });

  // test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient_Revert_PartialExpired
  it('lenient batch search still reverts PriceFeedExpired on a matched stale ID', async function () {
    const now = await currentSeconds();
    const expiredTs = now - 181n;
    const requestedIds = ['0x11111111', '0xdeadbeef', '0x33333333'];
    const payloadIds = [requestedIds[0], dummyId(1), dummyId(2), dummyId(3), requestedIds[2]];
    const payloadPrices = Array(5).fill(100n * E18);
    const payloadTimestamps = [now, now, now, now, expiredTs];

    const payloadStart = payloadStartOf('getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 5 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    const words = expectRevertArgs(
      await run('getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, payloadStart, payloadEnd], extraData),
      'PriceFeedExpired(bytes4,uint256,uint256)'
    );
    expect(words[0] >> 224n).to.equal(BigInt(requestedIds[2]));
    expect(words[1]).to.equal(expiredTs);
    expect(words[2]).to.equal(now);
  });

  // test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient_Revert_PartialFutureDrift
  it('lenient batch search still reverts PriceFeedFutureDrift on a matched drifting ID', async function () {
    const now = await currentSeconds();
    const futureTs = now + 61n;
    const requestedIds = ['0x11111111', '0x22222222', '0x33333333'];
    const payloadIds = [requestedIds[0], dummyId(1), requestedIds[1], dummyId(3), requestedIds[2]];
    const payloadPrices = Array(5).fill(100n * E18);
    const payloadTimestamps = [futureTs, now, now, now, now];

    const payloadStart = payloadStartOf('getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 5 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    const words = expectRevertArgs(
      await run('getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatchedTransient(bytes4[],uint256,uint256)', [requestedIds, payloadStart, payloadEnd], extraData),
      'PriceFeedFutureDrift(bytes4,uint256,uint256)'
    );
    expect(words[0] >> 224n).to.equal(BigInt(requestedIds[0]));
    expect(words[1]).to.equal(futureTs);
    expect(words[2]).to.equal(now);
  });

  /* ————————————————————————————————————————————————————————————————————————
                    INTERNAL API (TRANSIENT): STRICT BATCH
  ———————————————————————————————————————————————————————————————————————— */

  // test_getVerifiedFeedDataBatchTransient_Success
  it('internal strict batch resolves multiple IDs from a verified payload', async function () {
    const now = await currentSeconds();
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now - 1n, now - 2n];
    const requestedIds = [ids[2], ids[0]];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
    const [rPrices, rTs] = twoUint256Return(await run('getVerifiedFeedDataBatchTransient(bytes4[])', [requestedIds], extraData));

    expect(rPrices).to.deep.equal([300n * E18, 100n * E18]);
    expect(rTs).to.deep.equal([now - 2n, now]);
  });

  // test_getVerifiedFeedDataBatchTransient_Success_DuplicateRequestedIDs
  it('internal strict batch resolves duplicate requested IDs independently', async function () {
    const now = await currentSeconds();
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now - 1n, now - 2n];
    const requestedIds = [ids[1], ids[1], ids[0]];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
    const [rPrices, rTs] = twoUint256Return(await run('getVerifiedFeedDataBatchTransient(bytes4[])', [requestedIds], extraData));

    expect(rPrices).to.deep.equal([prices[1], prices[1], prices[0]]);
    expect(rTs).to.deep.equal([timestamps[1], timestamps[1], timestamps[0]]);
  });

  // test_getVerifiedFeedDataBatchTransient_Revert_AnyUnmatched
  it('internal strict batch reverts UnmatchedFeedID when one ID is absent', async function () {
    const now = await currentSeconds();
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = Array(3).fill(now);
    const requestedIds = [ids[0], '0xdeadbeef'];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

    expectConstantRevert(
      await run('getVerifiedFeedDataBatchTransient(bytes4[])', [requestedIds], extraData),
      'UnmatchedFeedID(bytes4)',
      [BigInt('0xdeadbeef') << 224n]
    );
  });

  // test_getVerifiedFeedDataBatchTransient_Revert_PartialExpired
  it('internal strict batch reverts PriceFeedExpired when one requested ID is stale', async function () {
    const now = await currentSeconds();
    const expiredTs = now - 181n;
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now, expiredTs];
    const requestedIds = [ids[2], ids[0]];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

    const words = expectRevertArgs(
      await run('getVerifiedFeedDataBatchTransient(bytes4[])', [requestedIds], extraData),
      'PriceFeedExpired(bytes4,uint256,uint256)'
    );
    expect(words[0] >> 224n).to.equal(BigInt(requestedIds[0]));
    expect(words[1]).to.equal(expiredTs);
    expect(words[2]).to.equal(now);
  });

  // test_getVerifiedFeedDataBatchTransient_Revert_PartialFutureDrift
  it('internal strict batch reverts PriceFeedFutureDrift for one drifting ID', async function () {
    const now = await currentSeconds();
    const futureTs = now + 61n;
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now, futureTs];
    const requestedIds = [ids[2], ids[0]];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

    const words = expectRevertArgs(
      await run('getVerifiedFeedDataBatchTransient(bytes4[])', [requestedIds], extraData),
      'PriceFeedFutureDrift(bytes4,uint256,uint256)'
    );
    expect(words[0] >> 224n).to.equal(BigInt(requestedIds[0]));
    expect(words[1]).to.equal(futureTs);
    expect(words[2]).to.equal(now);
  });

  // test_getVerifiedFeedDataBatchTransient_Revert_TamperedData
  it('internal strict batch reverts UnauthorizedSigner when the payload is tampered', async function () {
    const now = await currentSeconds();
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = Array(3).fill(now);
    const requestedIds = [ids[2], ids[0]];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
    const tampered = ethers.getBytes(extraData);
    tampered[0] ^= 0x01;

    expectConstantRevert(
      await run('getVerifiedFeedDataBatchTransient(bytes4[])', [requestedIds], ethers.hexlify(tampered)),
      'UnauthorizedSigner(address)'
    );
  });

  // test_getVerifiedFeedDataBatchTransient_Success_EmptyFeedIds
  it('internal strict batch short-circuits on empty feedIds before authentication', async function () {
    const [prices, ts] = twoUint256Return(await run('getVerifiedFeedDataBatchTransient(bytes4[])', [[]], null));
    expect(prices).to.have.lengthOf(0);
    expect(ts).to.have.lengthOf(0);
  });

  /* ————————————————————————————————————————————————————————————————————————
                      INTERNAL API (TRANSIENT): LENIENT BATCH
  ———————————————————————————————————————————————————————————————————————— */

  // test_getVerifiedFeedDataBatchLenientTransient_Success_Mixed
  it('internal lenient batch returns zeros for missing IDs alongside verified hits', async function () {
    const now = await currentSeconds();
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now - 1n, now - 2n];
    const requestedIds = [ids[1], '0xdeadbeef'];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
    const [rPrices, rTs] = twoUint256Return(await run('getVerifiedFeedDataBatchLenientTransient(bytes4[])', [requestedIds], extraData));

    expect(rPrices).to.deep.equal([prices[1], 0n]);
    expect(rTs).to.deep.equal([timestamps[1], 0n]);
  });

  // test_getVerifiedFeedDataBatchLenientTransient_Success_DuplicateMissingIDs
  it('internal lenient batch returns one zero-fallback per duplicate missing ID', async function () {
    const now = await currentSeconds();
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now - 1n, now - 2n];
    const requestedIds = ['0xdeadbeef', ids[2], '0xdeadbeef'];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
    const [rPrices, rTs] = twoUint256Return(await run('getVerifiedFeedDataBatchLenientTransient(bytes4[])', [requestedIds], extraData));

    expect(rPrices).to.deep.equal([0n, prices[2], 0n]);
    expect(rTs).to.deep.equal([0n, timestamps[2], 0n]);
  });

  // test_getVerifiedFeedDataBatchLenientTransient_Revert_PartialExpired
  it('internal lenient batch reverts PriceFeedExpired when a matched ID is stale', async function () {
    const now = await currentSeconds();
    const expiredTs = now - 181n;
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now - 1n, expiredTs];
    const requestedIds = [ids[0], ids[2]];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);

    const words = expectRevertArgs(
      await run('getVerifiedFeedDataBatchLenientTransient(bytes4[])', [requestedIds], extraData),
      'PriceFeedExpired(bytes4,uint256,uint256)'
    );
    expect(words[0] >> 224n).to.equal(BigInt(requestedIds[1]));
    expect(words[1]).to.equal(expiredTs);
    expect(words[2]).to.equal(now);
  });

  // test_getVerifiedFeedDataBatchLenientTransient_Revert_PartialFutureDrift
  it('internal lenient batch reverts PriceFeedFutureDrift for one drifting ID', async function () {
    const now = await currentSeconds();
    const futureTs = now + 61n;
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, futureTs, now - 2n];
    const requestedIds = [ids[0], ids[1]];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
    const words = expectRevertArgs(
      await run('getVerifiedFeedDataBatchLenientTransient(bytes4[])', [requestedIds], extraData),
      'PriceFeedFutureDrift(bytes4,uint256,uint256)'
    );
    expect(words[0] >> 224n).to.equal(BigInt(requestedIds[1]));
    expect(words[1]).to.equal(futureTs);
    expect(words[2]).to.equal(now);
  });

  // test_getVerifiedFeedDataBatchLenientTransient_Revert_TamperedData
  it('internal lenient batch reverts UnauthorizedSigner when the payload is tampered', async function () {
    const now = await currentSeconds();
    const ids = [dummyId(0), dummyId(1), dummyId(2)];
    const prices = [100n * E18, 200n * E18, 300n * E18];
    const timestamps = [now, now - 1n, now - 2n];

    const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
    const tampered = ethers.getBytes(extraData);
    tampered[0] ^= 0x01;

    expectConstantRevert(
      await run('getVerifiedFeedDataBatchLenientTransient(bytes4[])', [ids], ethers.hexlify(tampered)),
      'UnauthorizedSigner(address)'
    );
  });

  // test_getVerifiedFeedDataBatchLenientTransient_Success_EmptyFeedIds
  it('internal lenient batch short-circuits on empty feedIds before authentication', async function () {
    const [prices, ts] = twoUint256Return(await run('getVerifiedFeedDataBatchLenientTransient(bytes4[])', [[]], null));
    expect(prices).to.have.lengthOf(0);
    expect(ts).to.have.lengthOf(0);
  });

  /* ————————————————————————————————————————————————————————————————————————
                FEED ID VALIDATION: FOREIGN TRANSIENT DATA REJECTION
  ———————————————————————————————————————————————————————————————————————— */

  // test_strictBatch_Revert_ForeignTransientDataRejected
  it('strict mode rejects foreign transient data with a mismatched feed ID prefix', async function () {
    const now = await currentSeconds();
    const payloadIds = ['0xbbbbbbbb', '0xcccccccc', '0xdddddddd'];
    const payloadPrices = [100n * E18, 200n * E18, 300n * E18];
    const payloadTimestamps = Array(3).fill(now);
    const foreign = foreignWord(now);
    const poisonedIds = [TARGET_ID];
    const requestedIds = [TARGET_ID];

    const payloadStart = payloadStartOf('strictBatchWithForeignTransientData(bytes4[],bytes32,bytes4[],uint256,uint256)', [poisonedIds, ethers.ZeroHash, requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 3 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    expectConstantRevert(
      await run('strictBatchWithForeignTransientData(bytes4[],bytes32,bytes4[],uint256,uint256)', [poisonedIds, foreign, requestedIds, payloadStart, payloadEnd], extraData),
      'UnmatchedFeedID(bytes4)',
      [BigInt(TARGET_ID) << 224n]
    );
  });

  // test_lenientBatch_Success_ForeignTransientDataReturnsZero
  it('lenient batch returns zeros for slots holding foreign transient data', async function () {
    const now = await currentSeconds();
    const payloadIds = ['0xbbbbbbbb', '0xcccccccc', '0xdddddddd'];
    const payloadPrices = [100n * E18, 200n * E18, 300n * E18];
    const payloadTimestamps = Array(3).fill(now);
    const foreign = foreignWord(now);
    const poisonedIds = [TARGET_ID];
    const requestedIds = [TARGET_ID, payloadIds[0]];

    const payloadStart = payloadStartOf('lenientBatchWithForeignTransientData(bytes4[],bytes32,bytes4[],uint256,uint256)', [poisonedIds, ethers.ZeroHash, requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 3 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    const [prices, ts] = twoUint256Return(
      await run('lenientBatchWithForeignTransientData(bytes4[],bytes32,bytes4[],uint256,uint256)', [poisonedIds, foreign, requestedIds, payloadStart, payloadEnd], extraData)
    );

    expect(prices[0], 'Foreign transient data must be rejected: price should be 0').to.equal(0n);
    expect(ts[0], 'Foreign transient data must be rejected: timestamp should be 0').to.equal(0n);
    expect(prices[1], 'Legitimate feed should return correct price').to.equal(payloadPrices[0]);
    expect(ts[1], 'Legitimate feed should return correct timestamp').to.equal(payloadTimestamps[0]);
  });

  // test_strictBatch_Success_ForeignDataWithMatchingFeedIdIsAccepted
  it('strict batch accepts foreign data whose feed ID prefix matches the slot key', async function () {
    const now = await currentSeconds();
    const payloadIds = ['0xbbbbbbbb', '0xcccccccc'];
    const payloadPrices = [100n * E18, 200n * E18];
    const payloadTimestamps = Array(2).fill(now);
    const fakePrice = 777n * E18;
    const fakeTs = now - 1n;
    const foreign = ethers.toBeHex((BigInt(TARGET_ID) << 224n) | (fakePrice << 144n) | (fakeTs << 96n), 32);
    const poisonedIds = [TARGET_ID];
    const requestedIds = [TARGET_ID];

    const payloadStart = payloadStartOf('strictBatchWithForeignTransientData(bytes4[],bytes32,bytes4[],uint256,uint256)', [poisonedIds, ethers.ZeroHash, requestedIds, 0, 0]);
    const payloadEnd = payloadStart + 2 * FEED_PACKAGE_SIZE;
    const extraData = buildUnsignedExtraData(payloadIds, payloadPrices, payloadTimestamps);

    const [prices, ts] = twoUint256Return(
      await run('strictBatchWithForeignTransientData(bytes4[],bytes32,bytes4[],uint256,uint256)', [poisonedIds, foreign, requestedIds, payloadStart, payloadEnd], extraData)
    );

    expect(prices[0], 'Foreign data with matching feedId prefix passes validation').to.equal(fakePrice);
    expect(ts[0], 'Foreign data with matching feedId prefix passes validation').to.equal(fakeTs);
  });
});
