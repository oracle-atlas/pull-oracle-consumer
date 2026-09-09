// TronBox test for PullOracleCodec — port of test/unit/PullOracleCodec.t.sol.
// All calls run as constant (pure) calls on the real TVM.
//
// Omitted from the Foundry original:
//   - test_ParseMetadata_OffsetResilienceFuzz: fuzz stays in Foundry; a concrete
//     junk-between-args-and-extraData case is covered below.
//   - test_ParseFeedPackage_Fuzz: bit-extraction semantics covered concretely by
//     the max-values and noise-isolation cases.

const PullOracleCodecMock = artifacts.require('PullOracleCodecMock');
const ethers = require('ethers');
const {
  encodeCallData,
  buildSignedExtraData,
  expectConstantSuccess,
  expectConstantRevert,
  callConstantRaw,
  setBalance,
  MAGIC_MARKER,
  FEED_PACKAGE_SIZE,
  FOOTER_SIZE,
  MIN_CALLDATA_SIZE,
} = require('../test-utils');

// Mirrors test/utils/BaseTest.t.sol.
const PRIMARY_SIGNER_PK = '0x3984ba7c2f5d0b43eeed79c2f6498969596432ddce18ba031ef1a6d78b15c55b';

const bytesLen = (hex) => (hex.length - 2) / 2;

// Signed payload with `count` all-zero packages (mirrors BaseTest's
// _buildSignedExtraData over empty arrays). Signature validity is irrelevant
// to parseMetadata but kept for 1:1 parity.
const buildSignedExtraDataZeros = (count) =>
  buildSignedExtraData(
    PRIMARY_SIGNER_PK,
    Array(count).fill(0),
    Array(count).fill(0n),
    Array(count).fill(0)
  );

// Overwrite the count byte (at len - FOOTER_SIZE) in an extraData payload.
function withDeclaredCount(extraDataHex, declaredCount) {
  const bytes = Buffer.from(extraDataHex.slice(2), 'hex');
  bytes[bytes.length - FOOTER_SIZE] = declaredCount;
  return '0x' + bytes.toString('hex');
}

contract('PullOracleCodec', function (accounts) {
  let mock;

  before(async function () {
    await setBalance(accounts[0], 10000000);
    mock = await PullOracleCodecMock.new({ from: accounts[0] });
  });

  const run = (input) => callConstantRaw(mock.address, input, accounts[0]);

  describe('parseMetadata — happy path', function () {
    // test_ParseMetadata_WithCalldata
    it('parses extraData appended after standard function arguments', async function () {
      const count = 3;
      const callData = encodeCallData('parseMetadata(uint256)', [10]);
      const extraData = buildSignedExtraDataZeros(count);
      const input = callData + extraData.slice(2);

      const [start, end] = expectConstantSuccess(await run(input)).map(Number);
      expect(end - start).to.equal(count * FEED_PACKAGE_SIZE);
      expect(start).to.equal(bytesLen(callData));
      expect(end).to.equal(bytesLen(input) - FOOTER_SIZE);
    });

    // test_ParseMetadata_NoCalldata: bare 4-byte selector of parseMetadata(uint256).
    it('parses extraData as the sole payload after the selector', async function () {
      const count = 1;
      const selector = ethers.id('parseMetadata(uint256)').slice(2, 10);
      const input = '0x' + selector + buildSignedExtraDataZeros(count).slice(2);

      const [start, end] = expectConstantSuccess(await run(input)).map(Number);
      expect(end - start).to.equal(count * FEED_PACKAGE_SIZE);
      expect(start).to.equal(4);
      expect(end).to.equal(bytesLen(input) - FOOTER_SIZE);
    });

    // test_ParseMetadata_Boundary_MaxCount: count exactly equals maxPackageCount.
    it('accepts a count exactly equal to maxPackageCount', async function () {
      const count = 10;
      const input =
        encodeCallData('parseMetadata(uint256)', [count]) +
        buildSignedExtraDataZeros(count).slice(2);
      expectConstantSuccess(await run(input));
    });

    // Concrete stand-in for test_ParseMetadata_OffsetResilienceFuzz:
    // arbitrary junk sits between the business arguments and the extraData.
    it('parses extraData after junk between arguments and payload', async function () {
      const maxCount = 20;
      const count = 2;
      const junk = 'aabbccddeeff00'; // 7 arbitrary bytes
      const baseCall = encodeCallData('parseMetadata(uint256)', [maxCount]);
      const extraData = buildSignedExtraDataZeros(count);
      const input = '0x' + baseCall.slice(2) + junk + extraData.slice(2);

      const [start, end] = expectConstantSuccess(await run(input)).map(Number);
      expect(end - start).to.equal(count * FEED_PACKAGE_SIZE);
      expect(start).to.equal(bytesLen(input) - bytesLen(extraData));
      expect(end).to.equal(bytesLen(input) - FOOTER_SIZE);
    });

    // test_ParseMetadata_MaxDensity: maximum theoretical package density.
    it('parses the maximum uint8 package density (255)', async function () {
      const count = 255;
      const extraData = buildSignedExtraDataZeros(count);
      const input = encodeCallData('parseMetadata(uint256)', [count]) + extraData.slice(2);

      const [start, end] = expectConstantSuccess(await run(input)).map(Number);
      expect(end - start).to.equal(count * FEED_PACKAGE_SIZE);
      expect(start).to.equal(bytesLen(input) - bytesLen(extraData));
      expect(end).to.equal(bytesLen(input) - FOOTER_SIZE);
    });
  });

  describe('parseFeedPackage', function () {
    async function parseWord(word) {
      const wordHex = '0x' + word.toString(16).padStart(64, '0');
      return expectConstantSuccess(
        await callConstantRaw(
          mock.address,
          encodeCallData('parseFeedPackage(bytes32)', [wordHex]),
          accounts[0]
        )
      );
    }

    // test_ParseFeedPackage_MaxValues: [FeedID(4B)][Price(10B)][Time(6B)][Junk(12B)].
    it('extracts maximum boundary price and timestamp', async function () {
      const word = ((1n << 80n) - 1n) << 144n | ((1n << 48n) - 1n) << 96n;
      const [price, ts] = await parseWord(word);
      expect(price).to.equal((1n << 80n) - 1n);
      expect(ts).to.equal((1n << 48n) - 1n);
    });

    // test_ParseFeedPackage_NoiseIsolation: max noise in FeedID and Junk slots.
    it('strips MSB and LSB noise from the package word', async function () {
      const price = 500000000000000000000n; // 500 USD
      const ts = 1710000000n;
      const word =
        0xffffffffn << 224n |
        price << 144n |
        ts << 96n |
        (2n ** 256n - 1n) >> 160n;
      const [decodedPrice, decodedTs] = await parseWord(word);
      expect(decodedPrice).to.equal(price);
      expect(decodedTs).to.equal(ts);
    });
  });

  describe('parseMetadata — negative cases', function () {
    const markerHex = MAGIC_MARKER.toString(16).padStart(4, '0');
    // test_Revert_InsufficientMetadata: total calldata = MIN_CALLDATA_SIZE - 1.
    it('reverts InsufficientMetadata below the minimum calldata size', async function () {
      const callData = encodeCallData('parseMetadata(uint256)', [10]);
      const extraLen = MIN_CALLDATA_SIZE - bytesLen(callData) - 1;
      const input = callData + '00'.repeat(extraLen);
      expectConstantRevert(await run(input), 'InsufficientMetadata()');
    });

    // test_Revert_InvalidMarker: valid length, wrong magic marker.
    it('reverts InvalidMarker on a wrong magic marker', async function () {
      const callData = encodeCallData('parseMetadata(uint256)', [10]);
      const padding = MIN_CALLDATA_SIZE - bytesLen(callData) - 2;
      const wrongMarker = (MAGIC_MARKER + 1).toString(16).padStart(4, '0');
      const input = '0x' + callData.slice(2) + '00'.repeat(padding) + wrongMarker;
      expectConstantRevert(await run(input), 'InvalidMarker()');
    });

    // test_Revert_ZeroPackageCount: count byte explicitly zero.
    it('reverts ZeroPackageCount when the count byte is zero', async function () {
      const callData = encodeCallData('parseMetadata(uint256)', [10]);
      const input = callData + '00' + '00'.repeat(65) + markerHex;
      expectConstantRevert(await run(input), 'ZeroPackageCount()');
    });

    // test_Revert_ExceedsMaxPackageCount: count = maxAllowed + 1, error carries args.
    it('reverts ExceedsMaxPackageCount with actual and allowed counts', async function () {
      const maxAllowed = 10;
      const actualCount = maxAllowed + 1;
      const input =
        encodeCallData('parseMetadata(uint256)', [maxAllowed]) +
        actualCount.toString(16).padStart(2, '0') +
        '00'.repeat(65) +
        markerHex;
      expectConstantRevert(
        await run(input),
        'ExceedsMaxPackageCount(uint256,uint256)',
        [BigInt(actualCount), BigInt(maxAllowed)]
      );
    });

    // test_Revert_InsufficientFeedPackages: footer claims more packages than
    // the physical calldata supports.
    it('reverts InsufficientFeedPackages when declared count exceeds available space', async function () {
      const extraData = withDeclaredCount(buildSignedExtraDataZeros(2), 5);
      const input = encodeCallData('parseMetadata(uint256)', [20]) + extraData.slice(2);
      expectConstantRevert(await run(input), 'InsufficientFeedPackages()');
    });

    // test_Revert_InsufficientFeedPackages_MinimumGap: declared count exactly one
    // above the physical count, via the no-argument function.
    it('reverts InsufficientFeedPackages on the smallest possible gap', async function () {
      const extraData = withDeclaredCount(buildSignedExtraDataZeros(2), 3);
      const input =
        encodeCallData('parseMetadataWithoutBusinessCalldata()', []) + extraData.slice(2);
      expectConstantRevert(await run(input), 'InsufficientFeedPackages()');
    });
  });
});
