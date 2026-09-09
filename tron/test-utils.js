// Shared TronBox test helpers for the pull-oracle Tron (TVM) test suite.
//
// IMPORTANT: keep this file OUTSIDE the `test/` directory — TronBox globs every
// `*.js` under `test/` and would otherwise try to load it as a Mocha suite.
//
// Uses the `tronWeb` global injected by the TronBox test environment.
//
// GOTCHAS learned on TRE (do not regress):
//   - tronweb's triggerConstantContract THROWS on revert and discards the
//     response — constant calls go through the raw wallet/triggerconstantcontract
//     HTTP API instead (see callConstantRaw; note request() defaults to GET).
//   - A TVM constant-call revert surfaces as ret="FAILED"; constant_result
//     carries the revert data ([4B selector][ABI args]).
//   - ethers 6.17's concat() returns a 0x-prefixed hex STRING, not Uint8Array —
//     wrap with getBytes() whenever bytes are needed.

const { expect } = require('chai');
// Namespace import: ethers.<fn> at call sites keeps ethers helpers visually
// distinct from local ones — worthwhile given the concat/getBytes quirks
// documented in the GOTCHAS block above.
const ethers = require('ethers');

/* ————————————————————————————————————————————————————————————————————————
                            PROTOCOL CONSTANTS
    (mirrors src/constants/Constants.sol — do not re-derive)
———————————————————————————————————————————————————————————————————————— */

// Magic marker 0x7096, derived from the first two bytes of keccak256("ATLAS").
const MAGIC_MARKER = 0x7096;
// [4B FeedID][10B Price][6B Timestamp]
const FEED_PACKAGE_SIZE = 20;
// [1B Count][65B Signature][2B Marker]
const FOOTER_SIZE = 68;
// Absolute minimum bytes for a valid call: 4 (Selector) + 20 (one package) + 68 (Footer).
const MIN_CALLDATA_SIZE = 92;
// EIP-2 upper bound for the 's' component: floor(secp256k1 n / 2).
const MAX_LOW_S_VALUE = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0n;

// Tron-formatted zero address (0x41 prefix + 20 zero bytes).
const ZERO_ADDR = '410000000000000000000000000000000000000000';

/* ————————————————————————————————————————————————————————————————————————
                            SMALL UTILITIES
———————————————————————————————————————————————————————————————————————— */

const strip0x = (hex) => String(hex).replace(/^0x/, '');

// Left-pad a private key to 32 bytes — foundry's vm.addr/sign accept short
// keys like 0x01, ethers' secp256k1 layer does not.
const normalizePk = (pk) => ethers.zeroPadValue(pk, 32);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/* ————————————————————————————————————————————————————————————————————————
                            ADDRESS HELPERS
———————————————————————————————————————————————————————————————————————— */

// Derive the 0x-hex (EVM-style, 20-byte) address from a private key — mirrors
// foundry vm.addr. Pure JS: usable before the tronWeb global is ready.
function computeSignerAddress(pk) {
  return ethers.computeAddress(normalizePk(pk));
}

// 0x-hex 20-byte address → Tron 41-hex (for constructor args / TronWeb APIs).
// Pure counterpart of toHex() below (which routes through tronWeb and also
// accepts base58 input).
function toTronHex(address) {
  return '41' + strip0x(address).toLowerCase();
}

// Low 20 bytes of a 32-byte word (ABI-encoded address) → 0x-hex address.
function wordToAddress(word) {
  return '0x' + BigInt(word).toString(16).padStart(64, '0').slice(24);
}

// Normalize any Tron address (base58 / 41-hex / 0x-hex) to lowercase 41-hex.
function toHex(address) {
  return tronWeb.address.toHex(address).toLowerCase();
}

/* ————————————————————————————————————————————————————————————————————————
                        TEST SIGNERS (mirrors BaseTest.t.sol)
———————————————————————————————————————————————————————————————————————— */

const PRIMARY_SIGNER_PK = '0x3984ba7c2f5d0b43eeed79c2f6498969596432ddce18ba031ef1a6d78b15c55b';
const SECONDARY_SIGNER_PK = '0xcdfdcba39f49d5858113d6b142ee2128407bd65a9604af271a9cf31a32009131';
const UNAUTHORIZED_SIGNER_PK = '0x01';

// EVM-style 0x-hex addresses derived above (pure ethers — safe at module load).
const PRIMARY_SIGNER = ethers.computeAddress(normalizePk(PRIMARY_SIGNER_PK));
const SECONDARY_SIGNER = ethers.computeAddress(normalizePk(SECONDARY_SIGNER_PK));
const UNAUTHORIZED_SIGNER = ethers.computeAddress(normalizePk(UNAUTHORIZED_SIGNER_PK));

/* ————————————————————————————————————————————————————————————————————————
                            SIGNING HELPERS
———————————————————————————————————————————————————————————————————————— */

// Compute a custom-error selector from either a signature ("InvalidSignatureS()")
// or an already-computed selector passed as "0x...".
function errorSelector(reason) {
  return reason.startsWith('0x')
    ? reason.slice(2)
    : ethers.id(reason).slice(2, 10);
}

// Sign a raw digest → 65-byte signature [r(32)][s(32)][v(1)] as Uint8Array.
// v is packed as 27/28 (the oracle's convention, mirroring foundry vm.sign) and
// ethers' SigningKey always yields a canonical low-s, satisfying the EIP-2
// check in PullOracleSignature. concat() returns a hex string on ethers 6.17,
// so getBytes() here is load-bearing: it hex-decodes it back to bytes.
function signDigest(pk, digest) {
  const { r, s, yParity } = new ethers.SigningKey(normalizePk(pk)).sign(digest);
  return ethers.getBytes(ethers.concat([r, s, ethers.toBeHex(yParity + 27, 1)]));
}

// Same, as a 130-char hex string (no 0x prefix).
function signDigestHex(pk, digest) {
  return Buffer.from(signDigest(pk, digest)).toString('hex');
}

/* ————————————————————————————————————————————————————————————————————————
                    PAYLOAD BUILDERS (JS port of BaseTest.t.sol)
———————————————————————————————————————————————————————————————————————— */

// Pack feed packages: [ID (4B)][Price (10B)][Timestamp (6B)] per feed.
// feedIds: BigInt|number|'0x…' (4 bytes), prices/timestamps: BigInt|number.
function packFeedPackagesHex(feedIds, prices, timestamps) {
  const parts = [];
  for (let i = 0; i < feedIds.length; i++) {
    parts.push(
      BigInt(feedIds[i]).toString(16).padStart(8, '0') +
      BigInt(prices[i]).toString(16).padStart(20, '0') +
      BigInt(timestamps[i]).toString(16).padStart(12, '0')
    );
  }
  return '0x' + parts.join('');
}

// Signed extraData: [Packages][Count (1B)][Signature (65B)][Marker (2B)],
// signed over keccak256([Packages][Count]) — identical to BaseTest.t.sol.
function buildSignedExtraData(pk, feedIds, prices, timestamps) {
  const packages = strip0x(packFeedPackagesHex(feedIds, prices, timestamps));
  const countHex = feedIds.length.toString(16).padStart(2, '0');
  const sig = signDigestHex(pk, ethers.keccak256('0x' + packages + countHex));
  return '0x' + packages + countHex + sig + MAGIC_MARKER.toString(16).padStart(4, '0');
}

// Unsigned variant (65 zero bytes in the signature slot) for testing
// search-engine logic without authentication.
function buildUnsignedExtraData(feedIds, prices, timestamps) {
  const packages = strip0x(packFeedPackagesHex(feedIds, prices, timestamps));
  const countHex = feedIds.length.toString(16).padStart(2, '0');
  return '0x' + packages + countHex + '00'.repeat(65) + MAGIC_MARKER.toString(16).padStart(4, '0');
}

/* ————————————————————————————————————————————————————————————————————————
                        CALL / DECODE HELPERS
———————————————————————————————————————————————————————————————————————— */

// ABI-encode a function call head (selector + args) from a signature string.
function encodeCallData(signature, args) {
  return new ethers.Interface([`function ${signature}`]).encodeFunctionData(signature, args || []);
}

// Overwrite 32 bytes at `offset` with the big-endian encoding of `value`
// (BigInt|number) — surgical tampering of calldata fields (r / s / v).
// Indexed writes by design: ethers 6.17 helpers may hand back hex STRINGS,
// which have no TypedArray.set — and writes on strings silently no-op.
function writeWord(bytes, offset, value) {
  let v = BigInt(value);
  for (let i = offset + 31; i >= offset; i--) {
    bytes[i] = Number(v & 0xffn);
    v >>= 8n;
  }
}

// Decode a hex string into 32-byte words (BigInt). Accepts 0x prefix or not.
function decodeWords(hex) {
  const h = strip0x(hex).toLowerCase();
  expect(h.length % 64, `odd-length hex data: ${h}`).to.equal(0);
  const words = [];
  for (let i = 0; i < h.length; i += 64) {
    words.push(BigInt('0x' + h.slice(i, i + 64)));
  }
  return words;
}

// Decode an ABI-encoded (uint256[], uint256[]) return payload (e.g. batch
// search results) into two BigInt arrays. Offsets are byte-based, relative to
// the start of the return-data word stream.
function decodeTwoUint256Arrays(hex) {
  const words = decodeWords(hex);
  const out = [];
  for (let k = 0; k < 2; k++) {
    const wordIdx = Number(words[k]) / 32;
    const len = Number(words[wordIdx]);
    out.push(words.slice(wordIdx + 1, wordIdx + 1 + len));
  }
  return out;
}

// Execute a raw constant (view/pure) call with full calldata control.
// `input` is the complete calldata: [function head][oracle extraData] — the
// trailing extraData lands in calldata exactly like the relay service appends
// it. Returns the raw wallet/triggerconstantcontract JSON, whose
// `constant_result` carries return data OR revert data (see gotchas above).
async function callConstantRaw(contractAddress, input, from) {
  return tronWeb.fullNode.request(
    'wallet/triggerconstantcontract',
    {
      owner_address: tronWeb.address.toHex(from || tronWeb.defaultAddress.hex),
      contract_address: tronWeb.address.toHex(contractAddress),
      data: strip0x(input),
    },
    'post'
  );
}

// Convenience: encode head + append oracle extraData, then run callConstantRaw.
async function callConstant(contractAddress, signature, args, extraData, from) {
  const input = encodeCallData(signature, args) + (extraData ? strip0x(extraData) : '');
  return callConstantRaw(contractAddress, input, from);
}

function constantResultHex(res) {
  return (res.constant_result || [])
    .map((x) => strip0x(x).toLowerCase())
    .join('');
}

function constantRetText(res) {
  const ret = res && res.transaction && res.transaction.ret;
  if (!Array.isArray(ret)) return '';
  // TRE constant calls: success entries are empty objects (contractRet is not
  // populated), failures carry {ret: 'FAILED'} / {ret: 'OUT_OF_ENERGY'}.
  return ret
    .map((r) => {
      if (r && typeof r === 'object') return String(r.ret || r.contractRet || 'SUCCESS');
      return String(r);
    })
    .join('|');
}

// Assert a constant call succeeded and return the decoded return-data words.
function expectConstantSuccess(res) {
  const ret = constantRetText(res);
  expect(
    ret,
    `constant call failed, ret="${ret}", response=${JSON.stringify(res)}`
  ).to.not.match(/REVERT|FAILED/);
  const hex = constantResultHex(res);
  expect(hex, `no constant_result for successful call, ret="${ret}", response=${JSON.stringify(res)}`).to.not.be.empty;
  return decodeWords(hex);
}

// Assert a revert selector and return the decoded error-argument words
// (post-selector) for per-argument assertions.
function expectRevertArgs(res, signature) {
  expectConstantRevert(res, signature);
  return decodeWords(constantResultHex(res).slice(8));
}

// Assert a constant call to a void function succeeded (no revert, no return
// data to decode).
function expectVoidSuccess(res) {
  const ret = constantRetText(res);
  expect(
    ret,
    `constant call failed, ret="${ret}", response=${JSON.stringify(res)}`
  ).to.not.match(/REVERT|FAILED/);
}

// Assert a constant (view) call reverted with a specific custom error.
// expectedWords: optional array of BigInt|number for the error arguments
// (each compared against the corresponding 32-byte word after the selector).
function expectConstantRevert(res, reason, expectedWords) {
  const ret = constantRetText(res);
  expect(ret, `expected constant call to revert, ret="${ret}", response=${JSON.stringify(res)}`).to.include(
    'FAILED'
  );
  const hex = constantResultHex(res);
  const selector = errorSelector(reason);
  expect(
    hex.startsWith(selector),
    `expected revert ${reason} (0x${selector}), got constant_result="${hex}"`
  ).to.be.true;
  if (expectedWords !== undefined) {
    const words = decodeWords(hex.slice(selector.length));
    expect(words, `revert args mismatch for ${reason}`).to.deep.equal(
      expectedWords.map((w) => BigInt(w))
    );
  }
}

/* ————————————————————————————————————————————————————————————————————————
                    TRANSACTION HELPERS (ported, proven on TRE)
———————————————————————————————————————————————————————————————————————— */

// Self-contained replacement for the tronbox-injected global: poll
// getTransactionInfo until the receipt (with `receipt.result`) is available.
async function waitForTransactionReceipt(txid, { timeoutMs = 30000, intervalMs = 300 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (; ;) {
    const info = await tronWeb.trx.getTransactionInfo(txid);
    if (info && Object.keys(info).length > 0 && info.receipt) return info;
    if (Date.now() > deadline) {
      throw new Error(`timeout waiting for transaction receipt: ${txid}`);
    }
    await sleep(intervalMs);
  }
}

// TronBox transaction methods resolve with a transaction id and do NOT throw on
// revert. Await the receipt and inspect receipt.result (SUCCESS / REVERT / ...),
// then verify the custom error selector in contractResult.
async function expectRevert(txPromise, reason) {
  const txid = await txPromise;
  const info = await waitForTransactionReceipt(txid);

  const status = info && info.receipt && info.receipt.result;
  expect(status, `Expected transaction to revert but received: ${JSON.stringify(info)}`).to.equal(
    'REVERT'
  );

  if (reason) {
    const resMessage = info && info.resMessage
      ? Buffer.from(info.resMessage, 'hex').toString('utf8')
      : '';
    const contractResultHex = constantResultHex(info);
    const selector = errorSelector(reason);

    expect(
      resMessage.toLowerCase().includes(reason.toLowerCase()) ||
      contractResultHex.includes(selector),
      `Expected revert reason "${reason}" (selector 0x${selector}), got resMessage="${resMessage}" contractResult="${JSON.stringify(info.contractResult)}"`
    ).to.be.true;
  }
  return info;
}

// TronBox Contract.new() THROWS a generic "contract has not been deployed"
// error when a constructor reverts; the deployment txid is embedded in the
// error text. Extract it, then poll until contractResult is populated (on TRE
// it can lag a block behind the receipt) and assert the selector.
async function expectDeployRevert(deployPromise, reason) {
  let threw = false;
  let error;
  try {
    await deployPromise;
  } catch (e) {
    threw = true;
    error = e;
  }
  if (!threw) expect.fail('Expected deployment to revert');
  if (reason) {
    const msg = String((error && (error.message || error)) || error);
    const m = msg.match(/value=([0-9a-fA-F]{64})/);
    expect(m, `Cannot extract txid from deploy error: ${msg}`).to.be.ok;
    let info;
    for (let i = 0; i < 40; i++) {
      info = await tronWeb.trx.getTransactionInfo(m[1]);
      const cr = (info && info.contractResult) || [];
      if (cr.length && strip0x(cr[0]) !== '') break;
      await sleep(500);
    }
    const contractResultHex = constantResultHex(info);
    expect(contractResultHex, 'no populated contractResult for failed deployment').to.be.ok;
    const selector = errorSelector(reason);
    expect(
      contractResultHex.startsWith(selector),
      `Expected deploy revert ${reason} (0x${selector}), got contractResult="${contractResultHex}"`
    ).to.be.true;
  }
}

// Assert that a transaction emitted the given event signature (topic0 match).
async function expectEvent(txPromise, eventSignature) {
  const txid = await txPromise;
  const info = await waitForTransactionReceipt(txid);
  const rawLogs = (info && (info.log || info.logs)) || [];
  const expectedTopic0 = id(eventSignature).slice(2).toLowerCase();

  const found = rawLogs.some((raw) => {
    const topics = Array.isArray(raw.topics) ? raw.topics : [];
    const topic0 = topics[0] ? String(topics[0]).replace(/^0x/, '').toLowerCase() : '';
    return topic0 === expectedTopic0;
  });

  expect(found, `Event ${eventSignature} not emitted (txid ${txid})`).to.be.true;
  return info;
}

// Top up an account's TRX on the local TRE node via the admin RPC
// (1 TRX = 1e6 SUN) so long suites never run out of deploy fees.
async function setBalance(address, trxAmount) {
  await tronWeb.send('tre_setAccountBalance', [address, trxAmount * 1e6]);
}

// Latest node block time in seconds, as BigInt — matches the BigInt domain
// of decoded return values / revert args, so assertions compare like-for-like.
async function currentSeconds() {
  const block = await tronWeb.trx.getCurrentBlock();
  return BigInt(block.block_header.raw_data.timestamp) / 1000n;
}

// Fetch all TRE accounts' private keys (accounts[i] ↔ privateKeys[i]).
async function getPrivateKeys() {
  const host = (tronWeb.fullNode && tronWeb.fullNode.host) || 'http://127.0.0.1:9090';
  const data = await (await fetch(`${host}/admin/accounts-json`)).json();
  return Array.isArray(data) ? data : data.privateKeys;
}

// Send a signed transaction with raw full calldata (for write paths and
// tx-based revert assertions). Returns the txid.
// NOTE: pass the payload via `input`, NOT `functionSelector` — the TRE node
// hashes the function_selector field as a function-name string.
async function sendRawCalldata(contractAddress, from, fullCalldata, pk) {
  const txObj = await tronWeb.transactionBuilder.triggerSmartContract(
    contractAddress,
    '',
    { from, input: fullCalldata },
    [],
    from
  );
  const signed = await tronWeb.trx.sign(txObj.transaction, pk);
  const result = await tronWeb.trx.sendRawTransaction(signed);
  return result.txid;
}

module.exports = {
  // protocol constants
  MAGIC_MARKER,
  FEED_PACKAGE_SIZE,
  FOOTER_SIZE,
  MIN_CALLDATA_SIZE,
  MAX_LOW_S_VALUE,
  ZERO_ADDR,
  // addresses
  computeSignerAddress,
  toTronHex,
  wordToAddress,
  toHex,
  // test signers
  PRIMARY_SIGNER_PK,
  SECONDARY_SIGNER_PK,
  UNAUTHORIZED_SIGNER_PK,
  PRIMARY_SIGNER,
  SECONDARY_SIGNER,
  UNAUTHORIZED_SIGNER,
  // signing
  errorSelector,
  signDigest,
  signDigestHex,
  // payload builders
  packFeedPackagesHex,
  buildSignedExtraData,
  buildUnsignedExtraData,
  // calls
  encodeCallData,
  writeWord,
  decodeWords,
  decodeTwoUint256Arrays,
  callConstantRaw,
  callConstant,
  constantResultHex,
  constantRetText,
  expectConstantSuccess,
  expectVoidSuccess,
  expectConstantRevert,
  expectRevertArgs,
  // transactions
  sleep,
  waitForTransactionReceipt,
  expectRevert,
  expectDeployRevert,
  expectEvent,
  setBalance,
  currentSeconds,
  getPrivateKeys,
  sendRawCalldata,
};
