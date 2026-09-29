import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { maxUint256 } from 'viem';
import { amount, bound, assertQuote, assertFresh, inWindow } from '../src/math.js';
import { addresses, abis, approvalFor, tradeRequest } from '../src/chain.js';

test('money inputs and slippage preserve integer precision and reject ambiguous amounts', () => {
  assert.equal(amount('990.000000000000000001'), 990000000000000000001n);
  for (const s of ['-1', '1e3', '0', '1.0000000000000000001', 'NaN', 'Infinity', '1,000', '.1', '1.', `${maxUint256}0`]) assert.throws(() => amount(s));
  assert.equal(bound(1n, 50, true), 2n);
  assert.equal(bound(1n, 50), 0n);
  assert.equal(bound(7000000n, 50, true), 7035000n);
  assert.equal(bound(7000000n, 50), 6965000n);
  assert.throws(() => bound(1n, 10000));
  assert.throws(() => bound(maxUint256, 50, true));
});

test('expired, changed-wallet and stale-block data cannot authorize a transaction', () => {
  const q = { key: 'wallet:amount:mode', expires: 1000 };
  assertQuote(q, q.key, 999);
  assert.throws(() => assertQuote(q, q.key, 1000));
  assert.throws(() => assertQuote(q, 'another-wallet:amount:mode', 900));
  assert.throws(() => assertQuote(null, q.key));
  assertFresh({ timestamp: 1000n }, 1000000);
  assert.throws(() => assertFresh({ timestamp: 1n }, 1000000));
  assert.throws(() => assertFresh({ timestamp: 1500n }, 1000000));
});

test('approval and transaction targets, recipient and limits match the reviewed quote', () => {
  const account = '0x1111111111111111111111111111111111111111';
  const q = { mode: 'mint', route: 'usdc', shares: 10n ** 18n, limit: 125000n, minimums: Array(8).fill(42n) };
  const a = approvalFor(q), mint = tradeRequest(q, account, 123n);
  assert.equal(a.amount, q.limit);
  assert.equal(mint.address, addresses.USDCGateway);
  assert.deepEqual(mint.args, [q.shares, q.limit, account, 123n]);
  q.mode = 'redeem';
  assert.equal(approvalFor(q).token, addresses.M7Vault);
  assert.equal(approvalFor(q).amount, q.shares);
  assert.equal(tradeRequest(q, account, 123n).functionName, 'redeemToUSDC');
  q.route = 'basket';
  assert.equal(approvalFor(q), null);
  const basket = tradeRequest(q, account, 123n);
  assert.equal(basket.address, addresses.M7Vault);
  assert.equal(basket.functionName, 'redeemBasketWithClaims');
  assert.deepEqual(basket.args, [q.shares, q.minimums, account, 123n]);
});

test('the reset UI follows the contract UTC weekday window', () => {
  const utc = value => BigInt(Date.parse(value) / 1000);
  assert.equal(inWindow(utc('2026-09-28T14:59:59Z')), false);
  assert.equal(inWindow(utc('2026-09-28T15:00:00Z')), true);
  assert.equal(inWindow(utc('2026-09-28T19:59:59Z')), true);
  assert.equal(inWindow(utc('2026-09-28T20:00:00Z')), false);
  assert.equal(inWindow(utc('2026-09-27T16:00:00Z')), false);
});

test('checked-in UI ABIs match the compiled deployed interfaces when artifacts are available', t => {
  // Solidity's internalType and unnamed-parameter labels do not affect the ABI.
  const normalize = item => JSON.parse(JSON.stringify(item, (key, value) => key === 'internalType' || key === 'name' && value === '' ? undefined : value));
  for (const [name, abi] of Object.entries(abis)) {
    let artifact;
    try { artifact = JSON.parse(readFileSync(new URL(`../../out/${name}.sol/${name}.json`, import.meta.url))); }
    catch (error) { if (error.code === 'ENOENT') { t.skip('Run forge build to check ABI drift.'); return; } throw error; }
    for (const item of abi) {
      const compiled = artifact.abi.find(a => a.type === item.type && a.name === item.name);
      assert.deepEqual(normalize(item), normalize(compiled), `${name}.${item.name} matches`);
    }
  }
});
