// TronBox test for PullOracleConsumerBase — port of test/unit/PullOracleConsumerBase.t.sol.
// All calls run as constant (view) calls on the real TVM.
//
// No cases omitted: the Foundry original has 44 concrete tests (no fuzz).
//
// TIMESTAMP STRATEGY: TRE has no warp. Timestamps are relative to the node's
// latest block time (currentSeconds) with skew margins — constant calls execute
// against a block mined up to ~3s after the fetch, so the Foundry offsets of
// ±1s past the 180s/60s boundaries (181/61) are widened to 240s/120s here.
// Boundary-exact cases (==180/==60) remain Foundry-only.

const PullOracleConsumerBaseMock = artifacts.require('PullOracleConsumerBaseMock');
const ethers = require('ethers');
const {
  decodeTwoUint256Arrays,
  encodeCallData,
  buildSignedExtraData,
  buildUnsignedExtraData,
  expectConstantSuccess,
  expectConstantRevert,
  expectRevertArgs,
  constantResultHex,
  callConstantRaw,
  setBalance,
  toTronHex,
  currentSeconds,
  FEED_PACKAGE_SIZE,
  PRIMARY_SIGNER_PK,
  SECONDARY_SIGNER_PK,
  UNAUTHORIZED_SIGNER_PK,
  PRIMARY_SIGNER,
  SECONDARY_SIGNER,
  UNAUTHORIZED_SIGNER,
} = require('../test-utils');

const TARGET_ID = '0x11223344';
const TARGET_PRICE = 50000n * 10n ** 18n;
const DUMMY_PRICE = 100n * 10n ** 18n;

// Dummy feed ID: unique per index, never collides with the targets above.
const dummyId = (i) => '0x' + ethers.keccak256(ethers.toUtf8Bytes('dummy' + i)).slice(2, 10);

// Flip the first byte of an extraData payload (breaks the signing digest).
const flipFirstByte = (extraDataHex) => {
  const bytes = Buffer.from(extraDataHex.slice(2), 'hex');
  bytes[0] ^= 0x01;
  return '0x' + bytes.toString('hex');
};

// Flip the last byte (corrupts the magic marker).
const flipLastByte = (extraDataHex) => {
  const bytes = Buffer.from(extraDataHex.slice(2), 'hex');
  bytes[bytes.length - 1] ^= 0x01;
  return '0x' + bytes.toString('hex');
};

contract('PullOracleConsumerBase', function (accounts) {
  let mock;

  before(async function () {
    await setBalance(accounts[0], 10000000);
    mock = await PullOracleConsumerBaseMock.new({ from: accounts[0] });
  });

  const run = (input) => callConstantRaw(mock.address, input, accounts[0]);
  const attach = (head, extraData) => head + extraData.slice(2);

  // payloadStart = ABI head length; encoded twice (measure, then bake in).
  function buildBatchInput(signature, requestedIds, payloadCount) {
    const placeholder = ethers.getBytes(encodeCallData(signature, [requestedIds, 0, 0]));
    const payloadStart = placeholder.length;
    const payloadEnd = payloadStart + payloadCount * FEED_PACKAGE_SIZE;
    const head = encodeCallData(signature, [requestedIds, payloadStart, payloadEnd]);
    return { head };
  }

  /* ————————————————————————————————————————————————————————————————————————
                              STRICT MODE: SINGLE SEARCH
      Low-level search over an unsigned payload via explicit pointers.
  ———————————————————————————————————————————————————————————————————————— */

  describe('strict single search', function () {
    const SIG = 'getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched(bytes4,uint256,uint256)';

    // test_getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched_Success
    it('finds and decodes the target ID in the payload', async function () {
      const now = await currentSeconds();
      const count = 3;
      // Target sits at index 2; dummies elsewhere.
      const ids = [dummyId(0), dummyId(1), TARGET_ID];
      const prices = [DUMMY_PRICE, DUMMY_PRICE, TARGET_PRICE];
      const timestamps = [now - 10n, now - 10n, now];

      const placeholder = ethers.getBytes(encodeCallData(SIG, [TARGET_ID, 0, 0]));
      const payloadStart = placeholder.length;
      const payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
      const input =
        ethers.hexlify(encodeCallData(SIG, [TARGET_ID, payloadStart, payloadEnd])) +
        buildUnsignedExtraData(ids, prices, timestamps).slice(2);

      const [price, ts] = expectConstantSuccess(await run(input));
      expect(price).to.equal(TARGET_PRICE);
      expect(ts).to.equal(now);
    });

    // test_getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched_Revert_UnmatchedFeedID
    it('reverts UnmatchedFeedID with the missing ID when absent', async function () {
      const now = await currentSeconds();
      const count = 4;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = Array(count).fill(DUMMY_PRICE);
      const timestamps = Array(count).fill(now);

      const placeholder = ethers.getBytes(encodeCallData(SIG, [TARGET_ID, 0, 0]));
      const payloadStart = placeholder.length;
      const payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
      const input =
        ethers.hexlify(encodeCallData(SIG, [TARGET_ID, payloadStart, payloadEnd])) +
        buildUnsignedExtraData(ids, prices, timestamps).slice(2);

      expectConstantRevert(await run(input), 'UnmatchedFeedID(bytes4)', [BigInt(TARGET_ID) << 224n]);
    });

    // test_getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched_Revert_PriceFeedExpired
    it('reverts PriceFeedExpired when the matched ID is stale', async function () {
      const now = await currentSeconds();
      const expiredTs = now - 240n; // beyond the 180s reference delay, skew-safe
      const count = 4;
      const ids = [dummyId(0), dummyId(1), TARGET_ID, dummyId(3)];
      const prices = [DUMMY_PRICE, DUMMY_PRICE, TARGET_PRICE, DUMMY_PRICE];
      const timestamps = [now, now, expiredTs, now];

      const placeholder = ethers.getBytes(encodeCallData(SIG, [TARGET_ID, 0, 0]));
      const payloadStart = placeholder.length;
      const payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
      const input =
        ethers.hexlify(encodeCallData(SIG, [TARGET_ID, payloadStart, payloadEnd])) +
        buildUnsignedExtraData(ids, prices, timestamps).slice(2);

      const words = expectRevertArgs(await run(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(TARGET_ID));
      expect(words[1]).to.equal(expiredTs);
      // The third arg is the executing block timestamp — assert a range.
      expect(words[2] >= now).to.be.true;
      expect(words[2] <= now + 3n).to.be.true;
    });

    // test_getAndValidateFeedValuesByIdFromExtraDataOrRevertIfUnmatched_Revert_PriceFeedFutureDrift
    it('reverts PriceFeedFutureDrift when the matched ID drifts too far ahead', async function () {
      const now = await currentSeconds();
      const futureTs = now + 120n; // beyond the 60s reference drift, skew-safe
      const count = 4;
      const ids = [dummyId(0), TARGET_ID, dummyId(2), dummyId(3)];
      const prices = [DUMMY_PRICE, TARGET_PRICE, DUMMY_PRICE, DUMMY_PRICE];
      const timestamps = [now, futureTs, now, now];

      const placeholder = ethers.getBytes(encodeCallData(SIG, [TARGET_ID, 0, 0]));
      const payloadStart = placeholder.length;
      const payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
      const input =
        ethers.hexlify(encodeCallData(SIG, [TARGET_ID, payloadStart, payloadEnd])) +
        buildUnsignedExtraData(ids, prices, timestamps).slice(2);

      const words = expectRevertArgs(await run(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(TARGET_ID));
      expect(words[1]).to.equal(futureTs);
      expect(words[2] >= now).to.be.true;
      expect(words[2] <= now + 3n).to.be.true;
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                              STRICT MODE: BATCH SEARCH
  ———————————————————————————————————————————————————————————————————————— */

  describe('strict batch search', function () {
    const SIG = 'getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched(bytes4[],uint256,uint256)';

    // Build the full input for a batch low-level search; payloadStart is the
    // ABI head length (computed, not hardcoded).
    // test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched_Success
    it('returns ordered batch results across a 5-package payload', async function () {
      const now = await currentSeconds();
      const payloadCount = 5;
      const requestedIds = ['0x11111111', '0x22222222', '0x33333333'];
      const expectedPrices = [100n * 10n ** 18n, 200n * 10n ** 18n, 300n * 10n ** 18n];

      const ids = [requestedIds[0], dummyId(1), requestedIds[1], dummyId(3), requestedIds[2]];
      const prices = [expectedPrices[0], 50n * 10n ** 18n, expectedPrices[1], 50n * 10n ** 18n, expectedPrices[2]];
      const timestamps = [now, now - 1n, now - 2n, now - 3n, now - 4n];

      const { head } = buildBatchInput(SIG, requestedIds, payloadCount);
      const input = attach(head, buildUnsignedExtraData(ids, prices, timestamps));

      const [rPrices, rTs] = decodeTwoUint256Arrays(constantResultHex(await run(input)));
      expect(rPrices.length).to.equal(3);
      expect(rTs.length).to.equal(3);
      expect(rPrices).to.deep.equal(expectedPrices);
      // Requested indices 0/2/4 carry timestamps now-0/-2/-4.
      expect(rTs).to.deep.equal([now, now - 2n, now - 4n]);
    });

    // test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched_Revert_PartialUnmatchedID
    it('reverts UnmatchedFeedID with the first missing requested ID', async function () {
      const now = await currentSeconds();
      const payloadCount = 5;
      const requestedIds = ['0x11111111', '0xdeadbeef', '0x33333333'];

      const ids = [requestedIds[0], dummyId(1), dummyId(2), dummyId(3), requestedIds[2]];
      const prices = Array(5).fill(DUMMY_PRICE);
      const timestamps = Array(5).fill(now);

      const { head } = buildBatchInput(SIG, requestedIds, payloadCount);
      const input = attach(head, buildUnsignedExtraData(ids, prices, timestamps));

      expectConstantRevert(await run(input), 'UnmatchedFeedID(bytes4)', [BigInt('0xdeadbeef') << 224n]);
    });

    // test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched_Revert_PartialExpired
    it('reverts PriceFeedExpired when one batch entry is stale', async function () {
      const now = await currentSeconds();
      const expiredTs = now - 240n;
      const payloadCount = 5;
      const requestedIds = ['0x11111111', '0x22222222', '0x33333333'];

      const ids = [requestedIds[0], dummyId(1), requestedIds[1], dummyId(3), requestedIds[2]];
      const prices = Array(5).fill(DUMMY_PRICE);
      const timestamps = [now, now, now, now, expiredTs];

      const { head } = buildBatchInput(SIG, requestedIds, payloadCount);
      const input = attach(head, buildUnsignedExtraData(ids, prices, timestamps));

      const words = expectRevertArgs(await run(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt('0x33333333'));
      expect(words[1]).to.equal(expiredTs);
    });

    // test_getAndValidateFeedValuesByIdsFromExtraDataOrRevertIfAnyUnmatched_Revert_PartialFutureDrift
    it('reverts PriceFeedFutureDrift when one batch entry drifts too far ahead', async function () {
      const now = await currentSeconds();
      const futureTs = now + 120n;
      const payloadCount = 5;
      const requestedIds = ['0x11111111', '0x22222222', '0x33333333'];

      const ids = [requestedIds[0], dummyId(1), requestedIds[1], dummyId(3), requestedIds[2]];
      const prices = Array(5).fill(DUMMY_PRICE);
      const timestamps = [now, now, futureTs, now, now];

      const { head } = buildBatchInput(SIG, requestedIds, payloadCount);
      const input = attach(head, buildUnsignedExtraData(ids, prices, timestamps));

      const words = expectRevertArgs(await run(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt('0x22222222'));
      expect(words[1]).to.equal(futureTs);
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                              LENIENT MODE: SINGLE SEARCH
  ———————————————————————————————————————————————————————————————————————— */

  describe('lenient single search', function () {
    const SIG = 'getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched(bytes4,uint256,uint256)';

    // test_getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched_Success
    it('finds the target ID in lenient mode', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = [dummyId(0), TARGET_ID, dummyId(2)];
      const prices = [DUMMY_PRICE, TARGET_PRICE, DUMMY_PRICE];
      const timestamps = [now - 5n, now, now - 5n];

      const placeholder = ethers.getBytes(encodeCallData(SIG, [TARGET_ID, 0, 0]));
      const payloadStart = placeholder.length;
      const payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
      const input =
        ethers.hexlify(encodeCallData(SIG, [TARGET_ID, payloadStart, payloadEnd])) +
        buildUnsignedExtraData(ids, prices, timestamps).slice(2);

      const [price, ts] = expectConstantSuccess(await run(input));
      expect(price).to.equal(TARGET_PRICE);
      expect(ts).to.equal(now);
    });

    // test_getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched_ReturnZero_IfUnmatched
    it('returns zero values instead of reverting when unmatched', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = Array(count).fill(DUMMY_PRICE);
      const timestamps = Array(count).fill(now);

      const placeholder = ethers.getBytes(encodeCallData(SIG, ['0xdeadbeef', 0, 0]));
      const payloadStart = placeholder.length;
      const payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
      const input =
        ethers.hexlify(encodeCallData(SIG, ['0xdeadbeef', payloadStart, payloadEnd])) +
        buildUnsignedExtraData(ids, prices, timestamps).slice(2);

      const [price, ts] = expectConstantSuccess(await run(input));
      expect(price).to.equal(0n);
      expect(ts).to.equal(0n);
    });

    // test_getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched_Revert_PriceFeedExpired
    it('still reverts PriceFeedExpired when matched but stale', async function () {
      const now = await currentSeconds();
      const expiredTs = now - 240n;
      const count = 4;
      const ids = [dummyId(0), dummyId(1), TARGET_ID, dummyId(3)];
      const prices = [DUMMY_PRICE, DUMMY_PRICE, TARGET_PRICE, DUMMY_PRICE];
      const timestamps = [now, now, expiredTs, now];

      const placeholder = ethers.getBytes(encodeCallData(SIG, [TARGET_ID, 0, 0]));
      const payloadStart = placeholder.length;
      const payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
      const input =
        ethers.hexlify(encodeCallData(SIG, [TARGET_ID, payloadStart, payloadEnd])) +
        buildUnsignedExtraData(ids, prices, timestamps).slice(2);

      const words = expectRevertArgs(await run(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(TARGET_ID));
      expect(words[1]).to.equal(expiredTs);
    });

    // test_getAndValidateFeedValuesByIdFromExtraDataOrZeroIfUnmatched_Revert_PriceFeedFutureDrift
    it('still reverts PriceFeedFutureDrift when matched but drifting', async function () {
      const now = await currentSeconds();
      const futureTs = now + 120n;
      const count = 4;
      const ids = [dummyId(0), dummyId(1), dummyId(2), TARGET_ID];
      const prices = [DUMMY_PRICE, DUMMY_PRICE, DUMMY_PRICE, TARGET_PRICE];
      const timestamps = [now, now, now, futureTs];

      const placeholder = ethers.getBytes(encodeCallData(SIG, [TARGET_ID, 0, 0]));
      const payloadStart = placeholder.length;
      const payloadEnd = payloadStart + count * FEED_PACKAGE_SIZE;
      const input =
        ethers.hexlify(encodeCallData(SIG, [TARGET_ID, payloadStart, payloadEnd])) +
        buildUnsignedExtraData(ids, prices, timestamps).slice(2);

      const words = expectRevertArgs(await run(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(TARGET_ID));
      expect(words[1]).to.equal(futureTs);
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                              LENIENT MODE: BATCH SEARCH
  ———————————————————————————————————————————————————————————————————————— */

  describe('lenient batch search', function () {
    const SIG = 'getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched(bytes4[],uint256,uint256)';

    // test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched_Success_PartialMissing
    it('fills zeros for missing IDs and keeps found ones in order', async function () {
      const now = await currentSeconds();
      const payloadCount = 5;
      const requestedIds = ['0x11111111', '0xdeadbeef', '0x33333333'];

      const ids = [requestedIds[0], dummyId(1), dummyId(2), dummyId(3), requestedIds[2]];
      const prices = [100n * 10n ** 18n, 50n * 10n ** 18n, 50n * 10n ** 18n, 50n * 10n ** 18n, 300n * 10n ** 18n];
      const timestamps = Array(5).fill(now);

      const { head } = buildBatchInput(SIG, requestedIds, payloadCount);
      const input = attach(head, buildUnsignedExtraData(ids, prices, timestamps));

      const [rPrices, rTs] = decodeTwoUint256Arrays(constantResultHex(await run(input)));
      expect(rPrices).to.deep.equal([100n * 10n ** 18n, 0n, 300n * 10n ** 18n]);
      expect(rTs).to.deep.equal([now, 0n, now]);
    });

    // test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched_Success_AllMissing
    it('returns all zeros when no requested ID exists', async function () {
      const now = await currentSeconds();
      const payloadCount = 5;
      const requestedIds = ['0xaaaaaaaa', '0xbbbbbbbb', '0xcccccccc'];

      const ids = Array.from({ length: payloadCount }, (_, i) => dummyId('other' + i));
      const prices = Array(payloadCount).fill(DUMMY_PRICE);
      const timestamps = Array(payloadCount).fill(now);

      const { head } = buildBatchInput(SIG, requestedIds, payloadCount);
      const input = attach(head, buildUnsignedExtraData(ids, prices, timestamps));

      const [rPrices, rTs] = decodeTwoUint256Arrays(constantResultHex(await run(input)));
      expect(rPrices).to.deep.equal([0n, 0n, 0n]);
      expect(rTs).to.deep.equal([0n, 0n, 0n]);
    });

    // test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched_Revert_PartialExpired
    it('still reverts PriceFeedExpired when a matched batch entry is stale', async function () {
      const now = await currentSeconds();
      const expiredTs = now - 240n;
      const payloadCount = 5;
      const requestedIds = ['0x11111111', '0xdeadbeef', '0x33333333'];

      const ids = [requestedIds[0], dummyId(1), dummyId(2), dummyId(3), requestedIds[2]];
      const prices = Array(5).fill(DUMMY_PRICE);
      const timestamps = [now, now, now, now, expiredTs];

      const { head } = buildBatchInput(SIG, requestedIds, payloadCount);
      const input = attach(head, buildUnsignedExtraData(ids, prices, timestamps));

      const words = expectRevertArgs(await run(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt('0x33333333'));
      expect(words[1]).to.equal(expiredTs);
    });

    // test_getAndValidateFeedValuesByIdsFromExtraDataOrZeroIfUnmatched_Revert_PartialFutureDrift
    it('still reverts PriceFeedFutureDrift with early-exit on the first hit', async function () {
      const now = await currentSeconds();
      const futureTs = now + 120n;
      const payloadCount = 5;
      const requestedIds = ['0x11111111', '0x22222222', '0x33333333'];

      const ids = [requestedIds[0], dummyId(1), requestedIds[1], dummyId(3), requestedIds[2]];
      const prices = Array(5).fill(DUMMY_PRICE);
      const timestamps = [futureTs, now, now, now, now];

      const { head } = buildBatchInput(SIG, requestedIds, payloadCount);
      const input = attach(head, buildUnsignedExtraData(ids, prices, timestamps));

      const words = expectRevertArgs(await run(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt('0x11111111'));
      expect(words[1]).to.equal(futureTs);
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                                  AUTHENTICATION
  ———————————————————————————————————————————————————————————————————————— */

  describe('authenticateAndUnpackExtraData', function () {
    const SIG = 'authenticateAndUnpackExtraData()';
    const runAuth = (extraData) => run('0x' + encodeCallData(SIG, []).slice(2) + extraData.slice(2));

    // test_authenticateAndUnpackExtraData_Success
    it('recovers pointers for a signed payload right after the selector', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = Array(count).fill(DUMMY_PRICE);
      const timestamps = Array(count).fill(now);

      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const [start, end] = expectConstantSuccess(await runAuth(extraData));
      expect(start).to.equal(4n);
      expect(end).to.equal(4n + BigInt(count * FEED_PACKAGE_SIZE));
    });

    // test_authenticateAndUnpackExtraData_Success_WithJunkData
    it('accommodates junk data between the selector and the extraData tail', async function () {
      const now = await currentSeconds();
      const count = 2;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = Array(count).fill(DUMMY_PRICE);
      const timestamps = Array(count).fill(now);

      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const junk = ethers.toUtf8Bytes('unaligned_junk_17'); // 18 bytes
      const input =
        '0x' + encodeCallData(SIG, []).slice(2) + ethers.hexlify(junk).slice(2) + extraData.slice(2);

      const [start, end] = expectConstantSuccess(await run(input));
      expect(start).to.equal(4n + BigInt(junk.length));
      expect(end).to.equal(4n + BigInt(junk.length + count * FEED_PACKAGE_SIZE));
    });

    // test_authenticateAndUnpackExtraData_Revert_UnauthorizedSigner
    it('reverts UnauthorizedSigner with the recovered address', async function () {
      const now = await currentSeconds();
      const count = 2;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = Array(count).fill(DUMMY_PRICE);
      const timestamps = Array(count).fill(now);

      const extraData = buildSignedExtraData(UNAUTHORIZED_SIGNER_PK, ids, prices, timestamps);
      const words = expectRevertArgs(await runAuth(extraData), 'UnauthorizedSigner(address)');
      expect(words[0]).to.equal(BigInt('0x' + toTronHex(UNAUTHORIZED_SIGNER)));
    });

    // test_authenticateAndUnpackExtraData_Revert_TamperedData
    it('reverts UnauthorizedSigner on tampered packages (selector-only match)', async function () {
      const now = await currentSeconds();
      const ids = [TARGET_ID];
      const prices = [TARGET_PRICE];
      const timestamps = [now];

      const extraData = flipFirstByte(
        buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps)
      );
      // Tampering yields a nondeterministic recovered address — assert the
      // selector only, exactly like foundry's expectPartialRevert.
      expectConstantRevert(await runAuth(extraData), 'UnauthorizedSigner(address)');
    });

    // test_authenticateAndUnpackExtraData_Revert_InvalidMagicMarker
    it('reverts InvalidMarker when the marker byte is corrupted', async function () {
      const now = await currentSeconds();
      const ids = [TARGET_ID];
      const prices = [TARGET_PRICE];
      const timestamps = [now];

      const extraData = flipLastByte(
        buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps)
      );
      expectConstantRevert(await runAuth(extraData), 'InvalidMarker()');
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                          INTERNAL API: STRICT SINGLE (getVerifiedFeedData)
  ———————————————————————————————————————————————————————————————————————— */

  describe('getVerifiedFeedData (strict single)', function () {
    const SIG = 'getVerifiedFeedData(bytes4)';

    // test_getVerifiedFeedData_Success
    it('returns the verified target feed via the SECONDARY signer', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), TARGET_ID, dummyId(2)];
      const prices = [DUMMY_PRICE, TARGET_PRICE, 300n * 10n ** 18n];
      const timestamps = [now, now, now - 2n];

      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [TARGET_ID]), extraData);

      const [price, ts] = expectConstantSuccess(await run(input));
      expect(price).to.equal(TARGET_PRICE);
      expect(ts).to.equal(now);
    });

    // test_getVerifiedFeedData_Revert_UnmatchedFeedID
    it('reverts UnmatchedFeedID for a missing ID (selector-only match)', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = Array(count).fill(now);

      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, ['0xdeadbeef']), extraData);

      expectConstantRevert(await run(input), 'UnmatchedFeedID(bytes4)');
    });

    // test_getVerifiedFeedData_Revert_TamperedData
    it('reverts UnauthorizedSigner when the signed payload is tampered', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = Array(count).fill(now);

      const extraData = flipFirstByte(
        buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps)
      );
      const input = attach(encodeCallData(SIG, [ids[0]]), extraData);

      expectConstantRevert(await run(input), 'UnauthorizedSigner(address)');
    });

    // test_getVerifiedFeedData_Revert_Expired
    it('reverts PriceFeedExpired when the requested feed is stale', async function () {
      const now = await currentSeconds();
      const expiredTs = now - 240n;
      const ids = [dummyId(0), dummyId(1), dummyId(2)];
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = [now, expiredTs, now];

      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [ids[1]]), extraData);

      const words = expectRevertArgs(await run(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(ids[1]));
      expect(words[1]).to.equal(expiredTs);
    });

    // test_getVerifiedFeedData_Revert_FutureDrift
    it('reverts PriceFeedFutureDrift when the requested feed drifts ahead', async function () {
      const now = await currentSeconds();
      const futureTs = now + 120n;
      const ids = [dummyId(0), dummyId(1), dummyId(2)];
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = [now, futureTs, now];

      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [ids[1]]), extraData);

      const words = expectRevertArgs(await run(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(ids[1]));
      expect(words[1]).to.equal(futureTs);
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                          INTERNAL API: STRICT BATCH (getVerifiedFeedDataBatch)
  ———————————————————————————————————————————————————————————————————————— */

  describe('getVerifiedFeedDataBatch (strict batch)', function () {
    const SIG = 'getVerifiedFeedDataBatch(bytes4[])';

    // test_getVerifiedFeedDataBatch_Success
    it('returns requested entries in request order', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = ids.map((_, i) => now - BigInt(i));

      const requestedIds = [ids[2], ids[0]];
      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [requestedIds]), extraData);

      const [rPrices, rTs] = decodeTwoUint256Arrays(constantResultHex(await run(input)));
      expect(rPrices).to.deep.equal([prices[2], prices[0]]);
      expect(rTs).to.deep.equal([timestamps[2], timestamps[0]]);
    });

    // test_getVerifiedFeedDataBatch_Success_DuplicateRequestedIDs
    it('resolves duplicate requested IDs independently', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = ids.map((_, i) => now - BigInt(i));

      const requestedIds = [ids[1], ids[1], ids[0]];
      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [requestedIds]), extraData);

      const [rPrices, rTs] = decodeTwoUint256Arrays(constantResultHex(await run(input)));
      expect(rPrices).to.deep.equal([prices[1], prices[1], prices[0]]);
      expect(rTs).to.deep.equal([timestamps[1], timestamps[1], timestamps[0]]);
    });

    // test_getVerifiedFeedDataBatch_Revert_AnyUnmatched
    it('reverts UnmatchedFeedID when one requested ID is missing', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = Array(count).fill(now);

      const requestedIds = [ids[0], '0xdeadbeef'];
      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [requestedIds]), extraData);

      expectConstantRevert(await run(input), 'UnmatchedFeedID(bytes4)', [BigInt('0xdeadbeef') << 224n]);
    });

    // test_getVerifiedFeedDataBatch_Revert_PartialExpired
    it('reverts PriceFeedExpired when one batch entry is stale', async function () {
      const now = await currentSeconds();
      const expiredTs = now - 240n;
      const ids = [dummyId(0), dummyId(1), dummyId(2)];
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = [now, now, expiredTs];

      const requestedIds = [ids[2], ids[0]];
      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [requestedIds]), extraData);

      const words = expectRevertArgs(await run(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(ids[2]));
      expect(words[1]).to.equal(expiredTs);
    });

    // test_getVerifiedFeedDataBatch_Revert_PartialFutureDrift
    it('reverts PriceFeedFutureDrift when one batch entry drifts ahead', async function () {
      const now = await currentSeconds();
      const futureTs = now + 120n;
      const ids = [dummyId(0), dummyId(1), dummyId(2)];
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = [now, now, futureTs];

      const requestedIds = [ids[2], ids[0]];
      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [requestedIds]), extraData);

      const words = expectRevertArgs(await run(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(ids[2]));
      expect(words[1]).to.equal(futureTs);
    });

    // test_getVerifiedFeedDataBatch_Revert_TamperedData
    it('reverts UnauthorizedSigner when the batch payload is tampered', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = Array(count).fill(now);

      const extraData = flipFirstByte(
        buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps)
      );
      const input = attach(encodeCallData(SIG, [[ids[2], ids[0]]]), extraData);

      expectConstantRevert(await run(input), 'UnauthorizedSigner(address)');
    });

    // test_getVerifiedFeedDataBatch_Success_EmptyFeedIds
    it('short-circuits an empty request before authentication', async function () {
      const input = encodeCallData(SIG, [[]]);
      const [rPrices, rTs] = decodeTwoUint256Arrays(constantResultHex(await run(input)));
      expect(rPrices.length).to.equal(0);
      expect(rTs.length).to.equal(0);
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                          INTERNAL API: LENIENT SINGLE (getVerifiedFeedDataLenient)
  ———————————————————————————————————————————————————————————————————————— */

  describe('getVerifiedFeedDataLenient (lenient single)', function () {
    const SIG = 'getVerifiedFeedDataLenient(bytes4)';

    // test_getVerifiedFeedDataLenient_Success
    it('returns the verified target feed in lenient mode', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), TARGET_ID, dummyId(2)];
      const prices = [DUMMY_PRICE, TARGET_PRICE, 300n * 10n ** 18n];
      const timestamps = [now - 2n, now, now];

      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [TARGET_ID]), extraData);

      const [price, ts] = expectConstantSuccess(await run(input));
      expect(price).to.equal(TARGET_PRICE);
      expect(ts).to.equal(now);
    });

    // test_getVerifiedFeedDataLenient_Zero_Unmatched
    it('returns zero values for a missing ID in lenient mode', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = ids.map((_, i) => now - BigInt(i));

      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, ['0xdeadbeef']), extraData);

      const [price, ts] = expectConstantSuccess(await run(input));
      expect(price).to.equal(0n);
      expect(ts).to.equal(0n);
    });

    // test_getVerifiedFeedDataLenient_Revert_Expired
    it('still reverts PriceFeedExpired on a stale matched feed', async function () {
      const now = await currentSeconds();
      const expiredTs = now - 240n;
      const ids = [dummyId(0), dummyId(1), dummyId(2)];
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = [now, expiredTs, now];

      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [ids[1]]), extraData);

      const words = expectRevertArgs(await run(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(ids[1]));
      expect(words[1]).to.equal(expiredTs);
    });

    // test_getVerifiedFeedDataLenient_Revert_FutureDrift
    it('still reverts PriceFeedFutureDrift on a drifting matched feed', async function () {
      const now = await currentSeconds();
      const futureTs = now + 120n;
      const ids = [dummyId(0), dummyId(1), dummyId(2)];
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = [now, futureTs, now];

      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [ids[1]]), extraData);

      const words = expectRevertArgs(await run(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(ids[1]));
      expect(words[1]).to.equal(futureTs);
    });

    // test_getVerifiedFeedDataLenient_Revert_TamperedData
    it('reverts UnauthorizedSigner when the lenient payload is tampered', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = ids.map((_, i) => now - BigInt(i));

      const extraData = flipFirstByte(
        buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps)
      );
      const input = attach(encodeCallData(SIG, [ids[0]]), extraData);

      expectConstantRevert(await run(input), 'UnauthorizedSigner(address)');
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                          INTERNAL API: LENIENT BATCH (getVerifiedFeedDataBatchLenient)
  ———————————————————————————————————————————————————————————————————————— */

  describe('getVerifiedFeedDataBatchLenient (lenient batch)', function () {
    const SIG = 'getVerifiedFeedDataBatchLenient(bytes4[])';

    // test_getVerifiedFeedDataBatchLenient_Success_Mixed
    it('mixes found entries and zero fallbacks in request order', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = ids.map((_, i) => now - BigInt(i));

      const requestedIds = [ids[1], '0xdeadbeef'];
      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [requestedIds]), extraData);

      const [rPrices, rTs] = decodeTwoUint256Arrays(constantResultHex(await run(input)));
      expect(rPrices).to.deep.equal([prices[1], 0n]);
      expect(rTs).to.deep.equal([timestamps[1], 0n]);
    });

    // test_getVerifiedFeedDataBatchLenient_Success_DuplicateMissingIDs
    it('returns zero fallbacks for duplicate missing IDs', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = ids.map((_, i) => now - BigInt(i));

      const requestedIds = ['0xdeadbeef', ids[2], '0xdeadbeef'];
      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [requestedIds]), extraData);

      const [rPrices, rTs] = decodeTwoUint256Arrays(constantResultHex(await run(input)));
      expect(rPrices).to.deep.equal([0n, prices[2], 0n]);
      expect(rTs).to.deep.equal([0n, timestamps[2], 0n]);
    });

    // test_getVerifiedFeedDataBatchLenient_Revert_PartialExpired
    it('reverts PriceFeedExpired when a lenient batch entry is stale', async function () {
      const now = await currentSeconds();
      const expiredTs = now - 240n;
      const ids = [dummyId(0), dummyId(1), dummyId(2)];
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = [now, now, expiredTs];

      const requestedIds = [ids[0], ids[2]];
      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [requestedIds]), extraData);

      const words = expectRevertArgs(await run(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(ids[2]));
      expect(words[1]).to.equal(expiredTs);
    });

    // test_getVerifiedFeedDataBatchLenient_Revert_PartialFutureDrift
    it('reverts PriceFeedFutureDrift when a lenient batch entry drifts ahead', async function () {
      const now = await currentSeconds();
      const futureTs = now + 120n;
      const ids = [dummyId(0), dummyId(1), dummyId(2)];
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = [now, futureTs, now];

      const requestedIds = [ids[0], ids[1]];
      const extraData = buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps);
      const input = attach(encodeCallData(SIG, [requestedIds]), extraData);

      const words = expectRevertArgs(await run(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
      expect(words[0] >> 224n).to.equal(BigInt(ids[1]));
      expect(words[1]).to.equal(futureTs);
    });

    // test_getVerifiedFeedDataBatchLenient_Revert_TamperedData
    it('reverts UnauthorizedSigner when the batch lenient payload is tampered', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = ids.map((_, i) => now - BigInt(i));

      const extraData = flipFirstByte(
        buildSignedExtraData(SECONDARY_SIGNER_PK, ids, prices, timestamps)
      );
      const input = attach(encodeCallData(SIG, [ids]), extraData);

      expectConstantRevert(await run(input), 'UnauthorizedSigner(address)');
    });

    // test_getVerifiedFeedDataBatchLenient_Success_EmptyFeedIds
    it('short-circuits an empty lenient batch before authentication', async function () {
      const input = encodeCallData(SIG, [[]]);
      const [rPrices, rTs] = decodeTwoUint256Arrays(constantResultHex(await run(input)));
      expect(rPrices.length).to.equal(0);
      expect(rTs.length).to.equal(0);
    });
  });
});
