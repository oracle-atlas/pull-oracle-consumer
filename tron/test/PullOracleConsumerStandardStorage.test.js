// TronBox test for PullOracleConsumerStandardStorage — port of
// test/unit/PullOracleConsumerStandardStorage.t.sol.
//
// EXECUTION MODEL: unlike the ConsumerBase suite (pure constant calls), the
// Storage mock's setters and execute* business functions are STATE-CHANGING —
// they run as broadcast transactions via the TronBox wrapper (setters, signer
// management) or raw signed calldata (execute* with trailing extraData).
// Tron receipts carry no return data, so write-path results are asserted
// through the mock's lastPrice/lastTimestamp/lastPrices/lastTimestamps
// getters.
//
// ISOLATION: every test gets a freshly deployed mock (beforeEach) — mirrors
// Foundry's per-test setUp and keeps the runtime-config mutable state clean.
//
// TIMESTAMP STRATEGY: no warp on TRE — but TRE mines on demand (no blocks
// without transactions, verified empirically), so constant calls execute
// against the SAME block that currentSeconds() reads: block.timestamp is
// exactly the fetched value, and Foundry-exact offsets (-INIT_DELAY-1 /
// +INIT_DRIFT+1) work directly. The integration tests are broadcast TXs —
// their block ts ≈ wall clock at mining, so drift payloads carry a one-block
// landing margin (+3n) on top of the drift offset.
//
// ADDRESS CONVENTIONS (verified on TRE): call-side address params accept both
// EVM 20-byte and Tron 21-byte (0x41) encodings; constant-call revert data
// args carry the 21-byte 0x41 form; TX-receipt revert data args and event
// topics carry the EVM 20-byte form.

const ConsumerStandardStorageTvmMock = artifacts.require('ConsumerStandardStorageTvmMock');
const { expect } = require('chai');
const ethers = require('ethers');
const {
  decodeWords,
  decodeBytes,
  constantResultHex,
  encodeCallData,
  buildSignedExtraData,
  expectTxSuccess,
  deployWithReceipt,
  expectRevert,
  expectConstructorRevert,
  expectVoidSuccess,
  expectRevertArgs,
  dummyId,
  waitForTransactionReceipt,
  callConstantRaw,
  sendRawCalldata,
  setBalance,
  currentSeconds,
  ZERO_ADDR,
  getPrivateKeys,
  PRIMARY_SIGNER_PK,
  UNAUTHORIZED_SIGNER_PK,
  PRIMARY_SIGNER,
  SECONDARY_SIGNER,
  UNAUTHORIZED_SIGNER,
  PRIMARY_SIGNER_TRON,
  SECONDARY_SIGNER_TRON,
  UNAUTHORIZED_SIGNER_TRON,
} = require('../test-utils');

const INIT_COUNT = 10n;
const INIT_DELAY = 60n;
const INIT_DRIFT = 30n;

const TEST_FEED_ID = '0x01020304';
const TEST_PRICE = 50000n * 10n ** 18n;
const DUMMY_PRICE = 100n * 10n ** 18n;

contract('PullOracleConsumerStandardStorage', function (accounts) {
  let mock;
  let pk0;

  before(async function () {
    await setBalance(accounts[0], 10000000);
    pk0 = (await getPrivateKeys())[0];
  });

  beforeEach(async function () {
    mock = await ConsumerStandardStorageTvmMock.new(
      INIT_COUNT,
      INIT_DELAY,
      INIT_DRIFT,
      [PRIMARY_SIGNER_TRON, SECONDARY_SIGNER_TRON],
      { from: accounts[0] }
    );
  });

  const run = (input) => callConstantRaw(mock.address, input, accounts[0]);
  const readOn = async function (addr, signature, args) {
    return decodeWords(constantResultHex(await callConstantRaw(addr, encodeCallData(signature, args || []), accounts[0])));
  };
  const read = async function (signature, args) {
    return decodeWords(constantResultHex(await run(encodeCallData(signature, args || []))));
  };
  const send = (input) => sendRawCalldata(mock.address, accounts[0], input, pk0);
  const readBytesHex = async (signature) => decodeBytes(await read(signature));

  function findLog(info, signature) {
    const topic0 = ethers.id(signature).slice(2);
    const log = (info.log || []).find((l) => (l.topics || [])[0] === topic0);
    expect(log, `event ${signature} not emitted`).to.exist;
    return log;
  }

  async function expectSignerUpdated(txPromise, addrEvm, authorized) {
    const txid = await txPromise;
    const info = await waitForTransactionReceipt(txid);
    const log = findLog(info, 'SignerStatusUpdated(address,bool)');
    // Event topics carry the EVM 20-byte address form (revert data uses the
    // 21-byte 0x41 form — the two channels differ on TVM).
    const expectedTopic = BigInt(addrEvm).toString(16).padStart(64, '0');
    expect(log.topics[1]).to.equal(expectedTopic);
    const [flag] = decodeWords(log.data);
    expect(flag).to.equal(authorized ? 1n : 0n);
  }

  async function expectConfigEvent(txPromise, signature, oldValue, newValue) {
    const txid = await txPromise;
    const info = await waitForTransactionReceipt(txid);
    const log = findLog(info, signature);
    const [oldW, newW] = decodeWords(log.data);
    expect(oldW).to.equal(oldValue);
    expect(newW).to.equal(newValue);
  }

  describe('constructor', function () {
    // test_Constructor_InitializesState
    it('initializes config and signer set from constructor args', async function () {
      expect(await read('getMaxPackageCount()')).to.deep.equal([INIT_COUNT]);
      expect(await read('getMaxDelay()')).to.deep.equal([INIT_DELAY]);
      expect(await read('getMaxFutureDrift()')).to.deep.equal([INIT_DRIFT]);
      expect(await read('isAuthorizedSigner(address)', [PRIMARY_SIGNER])).to.deep.equal([1n]);
      expect(await read('isAuthorizedSigner(address)', [SECONDARY_SIGNER])).to.deep.equal([1n]);
      expect(await read('isAuthorizedSigner(address)', [UNAUTHORIZED_SIGNER])).to.deep.equal([0n]);
    });

    // test_Constructor_EmitsSignerEvents
    it('emits SignerStatusUpdated for each initial signer', async function () {
      const { info } = await deployWithReceipt(
        ConsumerStandardStorageTvmMock.new(
          INIT_COUNT,
          INIT_DELAY,
          INIT_DRIFT,
          [PRIMARY_SIGNER_TRON, SECONDARY_SIGNER_TRON],
          { from: accounts[0] }
        )
      );
      expect(info.receipt.result).to.equal('SUCCESS');
      // Exactly two events, one per initial signer — nothing else.
      expect(info.log.length).to.equal(2);
      const sigTopic = ethers.id('SignerStatusUpdated(address,bool)').slice(2);
      expect(info.log[0].topics[0]).to.equal(sigTopic);
      expect(info.log[0].topics[1]).to.equal(BigInt(PRIMARY_SIGNER).toString(16).padStart(64, '0'));
      expect(decodeWords(info.log[0].data)).to.deep.equal([1n]);
      expect(info.log[1].topics[0]).to.equal(sigTopic);
      expect(info.log[1].topics[1]).to.equal(BigInt(SECONDARY_SIGNER).toString(16).padStart(64, '0'));
      expect(decodeWords(info.log[1].data)).to.deep.equal([1n]);
    });

    // test_Constructor_ZeroDrift_Allowed
    it('allows zero maxFutureDrift (strict policy)', async function () {
      const m = await ConsumerStandardStorageTvmMock.new(
        INIT_COUNT,
        INIT_DELAY,
        0,
        [PRIMARY_SIGNER_TRON],
        { from: accounts[0] }
      );
      expect(await readOn(m.address, 'getMaxFutureDrift()')).to.deep.equal([0n]);
    });

    // test_Constructor_EmptySigners_Allowed
    it('allows an empty initial signer array', async function () {
      const m = await ConsumerStandardStorageTvmMock.new(INIT_COUNT, INIT_DELAY, INIT_DRIFT, [], {
        from: accounts[0],
      });
      expect(
        (await readOn(m.address, 'getMaxPackageCount()'))
      ).to.deep.equal([INIT_COUNT]);
    });

    // test_Revert_Constructor_ZeroMaxPackageCount
    it('reverts on zero maxPackageCount', async function () {
      await expectConstructorRevert(ConsumerStandardStorageTvmMock, [0, INIT_DELAY, INIT_DRIFT, []], 'InvalidMaxPackageCount()', pk0);
    });

    // test_Revert_Constructor_ZeroMaxDelay
    it('reverts on zero maxDelay', async function () {
      await expectConstructorRevert(ConsumerStandardStorageTvmMock, [INIT_COUNT, 0, INIT_DRIFT, []], 'InvalidMaxDelay()', pk0);
    });

    // test_Revert_Constructor_ZeroAddressSigner
    it('reverts on a zero address in initial signers', async function () {
      await expectConstructorRevert(ConsumerStandardStorageTvmMock, [INIT_COUNT, INIT_DELAY, INIT_DRIFT, [ZERO_ADDR]], 'ZeroAddressSigner()', pk0);
    });

    // test_Revert_Constructor_DuplicateSigner
    it('reverts on a duplicate signer in initial signers', async function () {
      await expectConstructorRevert(
        ConsumerStandardStorageTvmMock,
        [
          INIT_COUNT,
          INIT_DELAY,
          INIT_DRIFT,
          [PRIMARY_SIGNER_TRON, SECONDARY_SIGNER_TRON, PRIMARY_SIGNER_TRON],
        ],
        'SignerStatusAlreadySet(address)',
        pk0
      );
    });
  });

  describe('config setters', function () {
    // test_SetMaxPackageCount_Success
    it('updates maxPackageCount and emits the event', async function () {
      const txid = mock.setMaxPackageCount(20);
      await expectConfigEvent(txid, 'MaxPackageCountUpdated(uint256,uint256)', INIT_COUNT, 20n);
      expect(await read('getMaxPackageCount()')).to.deep.equal([20n]);
    });

    // test_SetMaxPackageCount_FieldIsolation
    it('keeps delay and drift intact when updating maxPackageCount', async function () {
      await expectTxSuccess(mock.setMaxPackageCount(20));
      expect(await read('getMaxDelay()')).to.deep.equal([INIT_DELAY]);
      expect(await read('getMaxFutureDrift()')).to.deep.equal([INIT_DRIFT]);
    });

    // test_Revert_SetMaxPackageCount_Zero
    it('reverts on zero maxPackageCount', async function () {
      await expectRevert(mock.setMaxPackageCount(0), 'InvalidMaxPackageCount()');
    });

    // test_Revert_SetMaxPackageCount_SameValue
    it('reverts when setting maxPackageCount to the current value', async function () {
      await expectRevert(mock.setMaxPackageCount(INIT_COUNT), 'ConfigValueAlreadySet()');
    });

    // Concrete stand-in for test_SetMaxPackageCount_Fuzz
    it('roundtrips a different maxPackageCount without field corruption', async function () {
      await expectTxSuccess(mock.setMaxPackageCount(200));
      expect(await read('getMaxPackageCount()')).to.deep.equal([200n]);
      expect(await read('getMaxDelay()')).to.deep.equal([INIT_DELAY]);
      expect(await read('getMaxFutureDrift()')).to.deep.equal([INIT_DRIFT]);
    });

    // test_SetMaxDelay_Success
    it('updates maxDelay and emits the event', async function () {
      const txid = mock.setMaxDelay(120);
      await expectConfigEvent(txid, 'MaxDelayUpdated(uint256,uint256)', INIT_DELAY, 120n);
      expect(await read('getMaxDelay()')).to.deep.equal([120n]);
    });

    // test_SetMaxDelay_FieldIsolation
    it('keeps count and drift intact when updating maxDelay', async function () {
      await expectTxSuccess(mock.setMaxDelay(120));
      expect(await read('getMaxPackageCount()')).to.deep.equal([INIT_COUNT]);
      expect(await read('getMaxFutureDrift()')).to.deep.equal([INIT_DRIFT]);
    });

    // test_Revert_SetMaxDelay_Zero
    it('reverts on zero maxDelay', async function () {
      await expectRevert(mock.setMaxDelay(0), 'InvalidMaxDelay()');
    });

    // test_Revert_SetMaxDelay_SameValue
    it('reverts when setting maxDelay to the current value', async function () {
      await expectRevert(mock.setMaxDelay(INIT_DELAY), 'ConfigValueAlreadySet()');
    });

    // Concrete stand-in for test_SetMaxDelay_Fuzz
    it('roundtrips a different maxDelay without field corruption', async function () {
      await expectTxSuccess(mock.setMaxDelay(86400));
      expect(await read('getMaxDelay()')).to.deep.equal([86400n]);
      expect(await read('getMaxPackageCount()')).to.deep.equal([INIT_COUNT]);
      expect(await read('getMaxFutureDrift()')).to.deep.equal([INIT_DRIFT]);
    });

    // test_SetMaxFutureDrift_Success
    it('updates maxFutureDrift and emits the event', async function () {
      const txid = mock.setMaxFutureDrift(90);
      await expectConfigEvent(txid, 'MaxFutureDriftUpdated(uint256,uint256)', INIT_DRIFT, 90n);
      expect(await read('getMaxFutureDrift()')).to.deep.equal([90n]);
    });

    // test_SetMaxFutureDrift_FieldIsolation
    it('keeps count and delay intact when updating maxFutureDrift', async function () {
      await expectTxSuccess(mock.setMaxFutureDrift(60));
      expect(await read('getMaxPackageCount()')).to.deep.equal([INIT_COUNT]);
      expect(await read('getMaxDelay()')).to.deep.equal([INIT_DELAY]);
    });

    // test_SetMaxFutureDrift_Zero_Allowed
    it('accepts zero maxFutureDrift (strict policy)', async function () {
      await expectTxSuccess(mock.setMaxFutureDrift(0));
      expect(await read('getMaxFutureDrift()')).to.deep.equal([0n]);
    });

    // test_Revert_SetMaxFutureDrift_SameValue
    it('reverts when setting maxFutureDrift to the current value', async function () {
      await expectRevert(mock.setMaxFutureDrift(INIT_DRIFT), 'ConfigValueAlreadySet()');
    });

    // Concrete stand-in for test_SetMaxFutureDrift_Fuzz
    it('roundtrips a different maxFutureDrift without field corruption', async function () {
      await expectTxSuccess(mock.setMaxFutureDrift(45));
      expect(await read('getMaxFutureDrift()')).to.deep.equal([45n]);
      expect(await read('getMaxPackageCount()')).to.deep.equal([INIT_COUNT]);
      expect(await read('getMaxDelay()')).to.deep.equal([INIT_DELAY]);
    });
  });


  describe('signer management', function () {
    // test_SetSignerStatus_Add
    it('adds a new signer and emits the event', async function () {
      const txid = mock.setSignerStatus(UNAUTHORIZED_SIGNER_TRON, true);
      await expectSignerUpdated(txid, UNAUTHORIZED_SIGNER, true);
      expect(await read('isAuthorizedSigner(address)', [UNAUTHORIZED_SIGNER])).to.deep.equal([1n]);
    });

    // test_SetSignerStatus_Remove
    it('removes an existing signer and emits the event', async function () {
      const txid = mock.setSignerStatus(PRIMARY_SIGNER_TRON, false);
      await expectSignerUpdated(txid, PRIMARY_SIGNER, false);
      expect(await read('isAuthorizedSigner(address)', [PRIMARY_SIGNER])).to.deep.equal([0n]);
    });

    // test_SetSignerStatus_Remove_Isolation
    it('does not affect other signers when removing one', async function () {
      await expectTxSuccess(mock.setSignerStatus(PRIMARY_SIGNER_TRON, false));
      expect(await read('isAuthorizedSigner(address)', [PRIMARY_SIGNER])).to.deep.equal([0n]);
      expect(await read('isAuthorizedSigner(address)', [SECONDARY_SIGNER])).to.deep.equal([1n]);
    });

    // test_Revert_SetSignerStatus_AlreadySet_Add
    it('reverts when adding an already-authorized signer', async function () {
      const info = await expectRevert(
        mock.setSignerStatus(PRIMARY_SIGNER_TRON, true),
        'SignerStatusAlreadySet(address)'
      );
      const words = decodeWords(constantResultHex(info).slice(8));
      // TX revert data carries the EVM 20-byte address form.
      expect(words[0]).to.equal(BigInt(PRIMARY_SIGNER));
    });

    // test_Revert_SetSignerStatus_AlreadySet_Remove
    it('reverts when removing a non-authorized signer', async function () {
      const info = await expectRevert(
        mock.setSignerStatus(UNAUTHORIZED_SIGNER_TRON, false),
        'SignerStatusAlreadySet(address)'
      );
      const words = decodeWords(constantResultHex(info).slice(8));
      expect(words[0]).to.equal(BigInt(UNAUTHORIZED_SIGNER));
    });

    // test_Revert_SetSignerStatus_ZeroAddress
    it('reverts when adding the zero address', async function () {
      await expectRevert(mock.setSignerStatus(ZERO_ADDR, true), 'ZeroAddressSigner()');
    });

    // test_Revert_SetSignerStatus_ZeroAddress_Remove
    it('reverts when removing the zero address', async function () {
      await expectRevert(mock.setSignerStatus(ZERO_ADDR, false), 'ZeroAddressSigner()');
    });

    // test_SetSignerStatus_AddRemoveReAdd
    it('supports an add → remove → re-add cycle', async function () {
      await expectTxSuccess(mock.setSignerStatus(UNAUTHORIZED_SIGNER_TRON, true));
      expect(await read('isAuthorizedSigner(address)', [UNAUTHORIZED_SIGNER])).to.deep.equal([1n]);
      await expectTxSuccess(mock.setSignerStatus(UNAUTHORIZED_SIGNER_TRON, false));
      expect(await read('isAuthorizedSigner(address)', [UNAUTHORIZED_SIGNER])).to.deep.equal([0n]);
      await expectTxSuccess(mock.setSignerStatus(UNAUTHORIZED_SIGNER_TRON, true));
      expect(await read('isAuthorizedSigner(address)', [UNAUTHORIZED_SIGNER])).to.deep.equal([1n]);
    });
  });

  describe('hook implementation', function () {
    // test_Hook_GetMaxPackageCount
    it('exposes the storage-backed maxPackageCount hook', async function () {
      expect(await read('checkGetMaxPackageCount()')).to.deep.equal([INIT_COUNT]);
    });

    // test_Hook_GetMaxPackageCount_AfterUpdate
    it('reflects config updates in the hook', async function () {
      await expectTxSuccess(mock.setMaxPackageCount(50));
      expect(await read('checkGetMaxPackageCount()')).to.deep.equal([50n]);
    });

    // test_Hook_IsAuthorizedSigner_Authorized
    it('authorizes both initial signers via the hook', async function () {
      expect(await read('checkIsAuthorizedSigner(address)', [PRIMARY_SIGNER])).to.deep.equal([1n]);
      expect(await read('checkIsAuthorizedSigner(address)', [SECONDARY_SIGNER])).to.deep.equal([1n]);
    });

    // test_Hook_IsAuthorizedSigner_Unauthorized
    it('rejects an unauthorized signer via the hook', async function () {
      expect(await read('checkIsAuthorizedSigner(address)', [UNAUTHORIZED_SIGNER])).to.deep.equal([0n]);
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                  TIMESTAMP VALIDATION (STORAGE-BACKED CONFIG)
      validateTimestamp against the live config — setter updates take
      effect on the next validation call.
  ———————————————————————————————————————————————————————————————————————— */

  describe('timestamp validation (storage-backed config)', function () {
    const SIG = 'validateTimestamp(bytes4,uint256)';

    // test_ValidateTimestamp_Success
    it('accepts timestamps inside the delay and drift windows', async function () {
      const now = await currentSeconds();
      for (const ts of [now, now - INIT_DELAY, now + INIT_DRIFT]) {
        expectVoidSuccess(await run(encodeCallData(SIG, [TEST_FEED_ID, ts])));
      }
    });

    // test_Revert_ValidateTimestamp_Expired
    it('reverts PriceFeedExpired beyond the maxDelay', async function () {
      const now = await currentSeconds();
      const expiredTs = now - INIT_DELAY - 1n;
      const words = expectRevertArgs(
        await run(encodeCallData(SIG, [TEST_FEED_ID, expiredTs])),
        'PriceFeedExpired(bytes4,uint256,uint256)'
      );
      expect(words[0] >> 224n).to.equal(BigInt(TEST_FEED_ID));
      expect(words[1]).to.equal(expiredTs);
      expect(words[2]).to.equal(now);
    });

    // test_Revert_ValidateTimestamp_FutureDrift
    it('reverts PriceFeedFutureDrift beyond the maxFutureDrift', async function () {
      const now = await currentSeconds();
      const futureTs = now + INIT_DRIFT + 3n;
      const words = expectRevertArgs(
        await run(encodeCallData(SIG, [TEST_FEED_ID, futureTs])),
        'PriceFeedFutureDrift(bytes4,uint256,uint256)'
      );
      expect(words[0] >> 224n).to.equal(BigInt(TEST_FEED_ID));
      expect(words[1]).to.equal(futureTs);
      expect(words[2]).to.equal(now);
    });

    // test_ValidateTimestamp_AfterConfigUpdate
    it('honors a widened maxDelay for a previously-expired timestamp', async function () {
      const now = await currentSeconds();
      const ts = now - INIT_DELAY - 1n;
      expectRevertArgs(await run(encodeCallData(SIG, [TEST_FEED_ID, ts])), 'PriceFeedExpired(bytes4,uint256,uint256)');

      await expectTxSuccess(mock.setMaxDelay(120));
      expectVoidSuccess(await run(encodeCallData(SIG, [TEST_FEED_ID, ts])));
    });

    // test_Revert_ValidateTimestamp_ZeroDrift_RejectsFuture
    it('rejects any future timestamp when maxFutureDrift is zero', async function () {
      await expectTxSuccess(mock.setMaxFutureDrift(0));
      const now = await currentSeconds();
      expectVoidSuccess(await run(encodeCallData(SIG, [TEST_FEED_ID, now])));
      expectRevertArgs(
        await run(encodeCallData(SIG, [TEST_FEED_ID, now + 1n])),
        'PriceFeedFutureDrift(bytes4,uint256,uint256)'
      );
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                            SEQUENTIAL CONFIG MUTATION
  ———————————————————————————————————————————————————————————————————————— */

  describe('sequential config mutation', function () {
    // test_SequentialConfigUpdate
    it('chains all three config updates to the final state', async function () {
      await expectTxSuccess(mock.setMaxPackageCount(50));
      await expectTxSuccess(mock.setMaxDelay(300));
      await expectTxSuccess(mock.setMaxFutureDrift(120));
      expect(await read('getMaxPackageCount()')).to.deep.equal([50n]);
      expect(await read('getMaxDelay()')).to.deep.equal([300n]);
      expect(await read('getMaxFutureDrift()')).to.deep.equal([120n]);
    });

    // Concrete stand-in for test_SequentialConfigUpdate_Fuzz
    it('preserves all fields across chained updates (stand-in values)', async function () {
      await expectTxSuccess(mock.setMaxPackageCount(200));
      await expectTxSuccess(mock.setMaxDelay(86400));
      await expectTxSuccess(mock.setMaxFutureDrift(45));
      expect(await read('getMaxPackageCount()')).to.deep.equal([200n]);
      expect(await read('getMaxDelay()')).to.deep.equal([86400n]);
      expect(await read('getMaxFutureDrift()')).to.deep.equal([45n]);
    });
  });

  /* ————————————————————————————————————————————————————————————————————————
                            INTEGRATION: WRITE PATH
      executeWithFeedData* are state-changing (they record lastBusinessData),
      so they run as broadcast transactions with the signed payload appended
      to the calldata tail. Results are asserted through the mock's
      lastPrice/lastTimestamp(/Batch) getters (Tron receipts carry no return
      data).
  ———————————————————————————————————————————————————————————————————————— */

  // Whole-array getters (public array auto-getters only expose element
  // access) return ABI dynamic data: [offset(0x20)][len][values...].
  async function readUintArray(signature) {
    const words = await read(signature);
    const len = Number(words[1]);
    return words.slice(2, 2 + len);
  }

  describe('integration — executeWithFeedData (strict single)', function () {
    const SIG = 'executeWithFeedData(bytes4,bytes)';

    // test_Integration_ExecuteWithFeedData_Success
    it('verifies the feed, stores business data, and records the result', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), TEST_FEED_ID];
      const prices = [DUMMY_PRICE, TEST_PRICE];
      const timestamps = [now, now];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const business = '0xcafebabe';
      const input = encodeCallData(SIG, [TEST_FEED_ID, business]) + extraData.slice(2);

      await expectTxSuccess(send(input));
      expect(await read('lastPrice()')).to.deep.equal([TEST_PRICE]);
      expect(await read('lastTimestamp()')).to.deep.equal([now]);
      expect(await readBytesHex('lastBusinessData()')).to.equal(business);
    });

    // test_Integration_ExecuteWithFeedData_Revert_UnauthorizedSigner
    it('reverts UnauthorizedSigner for an unapproved payload signer', async function () {
      const now = await currentSeconds();
      const extraData = buildSignedExtraData(UNAUTHORIZED_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [now]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'UnauthorizedSigner(address)');
    });

    // test_Integration_ExecuteWithFeedData_Revert_Expired
    it('reverts PriceFeedExpired when the payload is stale', async function () {
      const now = await currentSeconds();
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [now - INIT_DELAY - 1n]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
    });

    // test_Integration_ExecuteWithFeedData_Revert_FutureDrift
    it('reverts PriceFeedFutureDrift when the payload drifts ahead', async function () {
      const now = await currentSeconds();
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [now + 3n + INIT_DRIFT]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
    });

    // test_Integration_ExecuteWithFeedData_ConfigUpdateTakesEffect_MaxDelay
    it('honors a widened maxDelay for previously-stale payloads', async function () {
      const now = await currentSeconds();
      const ts = now - INIT_DELAY - 1n;
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [ts]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedExpired(bytes4,uint256,uint256)');

      await expectTxSuccess(mock.setMaxDelay(120));
      await expectTxSuccess(send(input));
      expect(await read('lastPrice()')).to.deep.equal([TEST_PRICE]);
      expect(await read('lastTimestamp()')).to.deep.equal([ts]);
    });

    // test_Integration_ExecuteWithFeedData_ConfigUpdateTakesEffect_MaxFutureDrift
    it('honors a widened maxFutureDrift for previously-drifting payloads', async function () {
      const now = await currentSeconds();
      const ts = now + 3n + INIT_DRIFT;
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [ts]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');

      await expectTxSuccess(mock.setMaxFutureDrift(60));
      await expectTxSuccess(send(input));
      expect(await read('lastPrice()')).to.deep.equal([TEST_PRICE]);
      expect(await read('lastTimestamp()')).to.deep.equal([ts]);
    });

    // test_Integration_ExecuteWithFeedData_SignerUpdateTakesEffect_Add
    it('accepts a payload after its signer is added', async function () {
      const now = await currentSeconds();
      const extraData = buildSignedExtraData(UNAUTHORIZED_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [now]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'UnauthorizedSigner(address)');

      await expectTxSuccess(mock.setSignerStatus(UNAUTHORIZED_SIGNER_TRON, true));
      await expectTxSuccess(send(input));
      expect(await read('lastPrice()')).to.deep.equal([TEST_PRICE]);
    });

    // test_Integration_ExecuteWithFeedData_SignerUpdateTakesEffect_Remove
    it('rejects a payload after its signer is removed', async function () {
      const now = await currentSeconds();
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [now]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectTxSuccess(send(input));
      expect(await read('lastPrice()')).to.deep.equal([TEST_PRICE]);

      await expectTxSuccess(mock.setSignerStatus(PRIMARY_SIGNER_TRON, false));
      await expectRevert(send(input), 'UnauthorizedSigner(address)');
    });

    // test_Integration_ExecuteWithFeedData_Revert_ExceedsMaxPackageCount
    it('reverts ExceedsMaxPackageCount when the payload exceeds the limit', async function () {
      const now = await currentSeconds();
      const count = Number(INIT_COUNT) + 1;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = Array(count).fill(DUMMY_PRICE);
      const timestamps = Array(count).fill(now);
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'ExceedsMaxPackageCount(uint256,uint256)');
    });

    // test_Integration_ExecuteWithFeedData_ConfigUpdateTakesEffect_MaxPackageCount
    it('accepts a large payload after maxPackageCount is raised', async function () {
      const now = await currentSeconds();
      const count = Number(INIT_COUNT) + 1;
      const ids = Array.from({ length: count }, (_, i) => (i === 0 ? TEST_FEED_ID : dummyId(i)));
      const prices = ids.map((_, i) => (i === 0 ? TEST_PRICE : DUMMY_PRICE));
      const timestamps = Array(count).fill(now);
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'ExceedsMaxPackageCount(uint256,uint256)');

      await expectTxSuccess(mock.setMaxPackageCount(count));
      await expectTxSuccess(send(input));
      expect(await read('lastPrice()')).to.deep.equal([TEST_PRICE]);
    });
  });

  describe('integration — executeWithFeedDataLenient (lenient single)', function () {
    const SIG = 'executeWithFeedDataLenient(bytes4,bytes)';

    // test_Integration_ExecuteWithFeedDataLenient_Success_UnmatchedReturnsZero
    it('records zero results for an unmatched ID instead of reverting', async function () {
      const now = await currentSeconds();
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [dummyId(0)], [TEST_PRICE], [now]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0xcafebabe']) + extraData.slice(2);
      await expectTxSuccess(send(input));
      expect(await read('lastPrice()')).to.deep.equal([0n]);
      expect(await read('lastTimestamp()')).to.deep.equal([0n]);
      expect(await readBytesHex('lastBusinessData()')).to.equal('0xcafebabe');
    });

    // test_Integration_ExecuteWithFeedDataLenient_Revert_Expired
    it('still reverts PriceFeedExpired on a stale matched feed', async function () {
      const now = await currentSeconds();
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [now - INIT_DELAY - 1n]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
    });

    // test_Integration_ExecuteWithFeedDataLenient_Revert_FutureDrift
    it('still reverts PriceFeedFutureDrift on a drifting matched feed', async function () {
      const now = await currentSeconds();
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [now + 3n + INIT_DRIFT]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
    });

    // test_Integration_ExecuteWithFeedDataLenient_ConfigUpdateTakesEffect_MaxDelay
    it('honors a widened maxDelay in lenient mode', async function () {
      const now = await currentSeconds();
      const ts = now - INIT_DELAY - 1n;
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [ts]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedExpired(bytes4,uint256,uint256)');

      await expectTxSuccess(mock.setMaxDelay(120));
      await expectTxSuccess(send(input));
      expect(await read('lastPrice()')).to.deep.equal([TEST_PRICE]);
      expect(await read('lastTimestamp()')).to.deep.equal([ts]);
    });

    // test_Integration_ExecuteWithFeedDataLenient_ConfigUpdateTakesEffect_MaxFutureDrift
    it('honors a widened maxFutureDrift in lenient mode', async function () {
      const now = await currentSeconds();
      const ts = now + 3n + INIT_DRIFT;
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, [TEST_FEED_ID], [TEST_PRICE], [ts]);
      const input = encodeCallData(SIG, [TEST_FEED_ID, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');

      await expectTxSuccess(mock.setMaxFutureDrift(60));
      await expectTxSuccess(send(input));
      expect(await read('lastPrice()')).to.deep.equal([TEST_PRICE]);
      expect(await read('lastTimestamp()')).to.deep.equal([ts]);
    });
  });

  describe('integration — executeWithFeedDataBatch (strict batch)', function () {
    const SIG = 'executeWithFeedDataBatch(bytes4[],bytes)';

    // test_Integration_ExecuteWithFeedDataBatch_Success
    it('resolves the requested subset and records arrays', async function () {
      const now = await currentSeconds();
      const count = 3;
      const ids = Array.from({ length: count }, (_, i) => dummyId(i));
      const prices = ids.map((_, i) => BigInt(i + 1) * 100n * 10n ** 18n);
      const timestamps = ids.map((_, i) => now - BigInt(i));

      const requestedIds = [ids[2], ids[0]];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [requestedIds, '0xcafebabe']) + extraData.slice(2);

      await expectTxSuccess(send(input));
      const [rPrices, rTs] = [await readUintArray('lastPrices()'), await readUintArray('lastTimestamps()')];
      expect(rPrices).to.deep.equal([prices[2], prices[0]]);
      expect(rTs).to.deep.equal([timestamps[2], timestamps[0]]);
      expect(await readBytesHex('lastBusinessData()')).to.equal('0xcafebabe');
    });

    // test_Integration_ExecuteWithFeedDataBatch_Revert_UnmatchedFeedID
    it('reverts UnmatchedFeedID with the missing requested ID', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = Array(2).fill(DUMMY_PRICE);
      const timestamps = Array(2).fill(now);
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input =
        encodeCallData(SIG, [[ids[0], '0xdeadbeef'], '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'UnmatchedFeedID(bytes4)');
    });

    // test_Integration_ExecuteWithFeedDataBatch_Revert_PartialExpired
    it('reverts PriceFeedExpired when one batch entry is stale', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = Array(2).fill(DUMMY_PRICE);
      const timestamps = [now, now - INIT_DELAY - 1n];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [ids, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
    });

    // test_Integration_ExecuteWithFeedDataBatch_Revert_PartialFutureDrift
    it('reverts PriceFeedFutureDrift when one batch entry drifts ahead', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = Array(2).fill(DUMMY_PRICE);
      const timestamps = [now, now + INIT_DRIFT + 3n];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [ids, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
    });

    // test_Integration_ExecuteWithFeedDataBatch_ConfigUpdateTakesEffect_MaxDelay
    it('honors a widened maxDelay for a previously-stale batch', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = Array(2).fill(DUMMY_PRICE);
      const timestamps = [now, now - INIT_DELAY - 1n];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [ids, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedExpired(bytes4,uint256,uint256)');

      await expectTxSuccess(mock.setMaxDelay(120));
      await expectTxSuccess(send(input));
      expect(await readUintArray('lastPrices()')).to.deep.equal(prices);
      expect(await readUintArray('lastTimestamps()')).to.deep.equal([now, now - INIT_DELAY - 1n]);
    });

    // test_Integration_ExecuteWithFeedDataBatch_ConfigUpdateTakesEffect_MaxFutureDrift
    it('honors a widened maxFutureDrift for a previously-drifting batch', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = Array(2).fill(DUMMY_PRICE);
      const timestamps = [now, now + INIT_DRIFT + 3n];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [ids, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');

      await expectTxSuccess(mock.setMaxFutureDrift(90));
      await expectTxSuccess(send(input));
      expect(await readUintArray('lastPrices()')).to.deep.equal(prices);
      expect(await readUintArray('lastTimestamps()')).to.deep.equal([now, now + INIT_DRIFT + 3n]);
    });

    // test_Integration_ExecuteWithFeedDataBatch_Success_EmptyFeedIds
    it('short-circuits an empty batch before authentication', async function () {
      const input = encodeCallData(SIG, [[], '0xcafebabe']);
      await expectTxSuccess(send(input));
      expect(await readUintArray('lastPrices()')).to.deep.equal([]);
      expect(await readUintArray('lastTimestamps()')).to.deep.equal([]);
      expect(await readBytesHex('lastBusinessData()')).to.equal('0xcafebabe');
    });
  });

  describe('integration — executeWithFeedDataBatchLenient (lenient batch)', function () {
    const SIG = 'executeWithFeedDataBatchLenient(bytes4[],bytes)';

    // test_Integration_ExecuteWithFeedDataBatchLenient_Success_PartialUnmatched
    it('fills zero fallbacks for missing IDs in a lenient batch', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = [100n * 10n ** 18n, 200n * 10n ** 18n];
      const timestamps = [now, now];
      const requestedIds = [ids[0], '0xdeadbeef', ids[1]];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [requestedIds, '0x']) + extraData.slice(2);

      await expectTxSuccess(send(input));
      expect(await readUintArray('lastPrices()')).to.deep.equal([prices[0], 0n, prices[1]]);
      expect(await readUintArray('lastTimestamps()')).to.deep.equal([now, 0n, now]);
    });

    // test_Integration_ExecuteWithFeedDataBatchLenient_Revert_PartialExpired
    it('reverts PriceFeedExpired when a lenient batch entry is stale', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = Array(2).fill(DUMMY_PRICE);
      const timestamps = [now, now - INIT_DELAY - 1n];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [ids, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedExpired(bytes4,uint256,uint256)');
    });

    // test_Integration_ExecuteWithFeedDataBatchLenient_Revert_PartialFutureDrift
    it('reverts PriceFeedFutureDrift when a lenient batch entry drifts ahead', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = Array(2).fill(DUMMY_PRICE);
      const timestamps = [now, now + INIT_DRIFT + 3n];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [ids, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');
    });

    // test_Integration_ExecuteWithFeedDataBatchLenient_ConfigUpdateTakesEffect_MaxDelay
    it('honors a widened maxDelay in a lenient batch', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = Array(2).fill(DUMMY_PRICE);
      const timestamps = [now, now - INIT_DELAY - 1n];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [ids, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedExpired(bytes4,uint256,uint256)');

      await expectTxSuccess(mock.setMaxDelay(120));
      await expectTxSuccess(send(input));
      expect(await readUintArray('lastPrices()')).to.deep.equal(prices);
      expect(await readUintArray('lastTimestamps()')).to.deep.equal([now, now - INIT_DELAY - 1n]);
    });

    // test_Integration_ExecuteWithFeedDataBatchLenient_ConfigUpdateTakesEffect_MaxFutureDrift
    it('honors a widened maxFutureDrift in a lenient batch', async function () {
      const now = await currentSeconds();
      const ids = [dummyId(0), dummyId(1)];
      const prices = Array(2).fill(DUMMY_PRICE);
      const timestamps = [now, now + INIT_DRIFT + 3n];
      const extraData = buildSignedExtraData(PRIMARY_SIGNER_PK, ids, prices, timestamps);
      const input = encodeCallData(SIG, [ids, '0x']) + extraData.slice(2);
      await expectRevert(send(input), 'PriceFeedFutureDrift(bytes4,uint256,uint256)');

      await expectTxSuccess(mock.setMaxFutureDrift(60));
      await expectTxSuccess(send(input));
      expect(await readUintArray('lastPrices()')).to.deep.equal(prices);
      expect(await readUintArray('lastTimestamps()')).to.deep.equal([now, now + INIT_DRIFT + 3n]);
    });

    // test_Integration_ExecuteWithFeedDataBatchLenient_Success_EmptyFeedIds
    it('short-circuits an empty lenient batch before authentication', async function () {
      const input = encodeCallData(SIG, [[], '0xcafebabe']);
      await expectTxSuccess(send(input));
      expect(await readUintArray('lastPrices()')).to.deep.equal([]);
      expect(await readUintArray('lastTimestamps()')).to.deep.equal([]);
      expect(await readBytesHex('lastBusinessData()')).to.equal('0xcafebabe');
    });
  });
});
