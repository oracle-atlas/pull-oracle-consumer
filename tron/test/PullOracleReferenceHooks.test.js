// TronBox test for PullOracleReferenceHooks — port of test/unit/PullOracleReferenceHooks.t.sol.
// All calls run as constant calls on the real TVM.
//
// TIMESTAMP STRATEGY: no warp on TRE — timestamps are relative to the latest
// block time with skew margins. The Foundry boundary-exact sub-cases
// (==180s delay and ==60s drift passing) are not deterministically testable
// here and remain Foundry-only.
//
// ADDRESS ARGS: TVM accepts both EVM 20-byte and Tron 21-byte (0x41-prefixed)
// encodings for address parameters (verified empirically); revert data
// however emits the 21-byte 0x41 form.

const PullOracleReferenceHooksMock = artifacts.require('PullOracleReferenceHooksMock');
const {
  encodeCallData,
  expectConstantSuccess,
  expectVoidSuccess,
  expectRevertArgs,
  callConstantRaw,
  setBalance,
  currentSeconds,
} = require('../test-utils');

// The production Atlas Oracle signing key hardcoded in the reference hook.
const PRODUCTION_SIGNER = '0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600';
const TEST_FEED_ID = '0x01020304';

contract('PullOracleReferenceHooks', function (accounts) {
  let mock;

  before(async function () {
    await setBalance(accounts[0], 10000000);
    mock = await PullOracleReferenceHooksMock.new({ from: accounts[0] });
  });

  const run = (input) => callConstantRaw(mock.address, input, accounts[0]);

  describe('validateTimestamp', function () {
    const SIG = 'validateTimestamp(bytes4,uint256)';

    // test_ValidateTimestamp_Success: within delay and drift windows.
    it('accepts timestamps inside the delay and drift windows', async function () {
      const now = await currentSeconds();
      for (const ts of [now, now - 180n, now + 60n]) {
        expectVoidSuccess(await run(encodeCallData(SIG, [TEST_FEED_ID, ts])));
      }
    });

    // test_Revert_PriceFeedExpired: delay beyond 180s.
    it('reverts PriceFeedExpired when the timestamp is stale', async function () {
      const now = await currentSeconds();
      const expiredTs = now - 181n;
      const words = expectRevertArgs(
        await run(encodeCallData(SIG, [TEST_FEED_ID, expiredTs])),
        'PriceFeedExpired(bytes4,uint256,uint256)'
      );
      expect(words[0] >> 224n).to.equal(BigInt(TEST_FEED_ID));
      expect(words[1]).to.equal(expiredTs);
      expect(words[2]).to.equal(now);
    });

    // test_Revert_PriceFeedFutureDrift: drift beyond 60s.
    it('reverts PriceFeedFutureDrift when the timestamp drifts too far ahead', async function () {
      const now = await currentSeconds();
      const futureTs = now + 61n;
      const words = expectRevertArgs(
        await run(encodeCallData(SIG, [TEST_FEED_ID, futureTs])),
        'PriceFeedFutureDrift(bytes4,uint256,uint256)'
      );
      expect(words[0] >> 224n).to.equal(BigInt(TEST_FEED_ID));
      expect(words[1]).to.equal(futureTs);
      expect(words[2]).to.equal(now);
    });
  });

  describe('isAuthorizedSigner', function () {
    // test_IsAuthorizedSigner_Success
    it('returns true for the production signing key', async function () {
      const words = expectConstantSuccess(
        await run(encodeCallData('isAuthorizedSigner(address)', [PRODUCTION_SIGNER]))
      );
      expect(words[0]).to.equal(1n);
    });

    // test_IsAuthorizedSigner_Unauthorized_ReturnsFalse
    it('returns false for an unauthorized address', async function () {
      const dead = '0x' + '0'.repeat(36) + 'dead'; // address(0xdead), 20 bytes
      const words = expectConstantSuccess(
        await run(encodeCallData('isAuthorizedSigner(address)', [dead]))
      );
      expect(words[0]).to.equal(0n);
    });
  });
});
