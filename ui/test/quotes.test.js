import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sizeUSDC, bound } from '../src/math.js';
import { client, quoteTrade, tradeRequest, approvalFor } from '../src/chain.js';

const one = 10n ** 18n;
const account = '0x1111111111111111111111111111111111111111';

test('USDC sizing respects budgets and minimum receipts with price impact and rounding', async () => {
  for (const mode of ['mint', 'redeem']) {
    for (const target of [10000n, 123456n, 1000000n, 25000000n, 100000000n]) {
      let calls = 0;
      const quote = async shares => {
        calls++;
        const total = mode === 'mint' ? shares * 125000n / one + shares * shares / (one * one * 20n)
          : shares * 125000000n / (1000n * one + shares);
        return { shares, total, limit: bound(total, 50, mode === 'mint') };
      };
      const q = await sizeUSDC({ mode, target, quote, maxShares: 100000n * one });
      assert.ok(mode === 'mint' ? q.limit <= target : q.limit >= target, `${mode}: ${target}`);
      assert.ok((q.limit > target ? q.limit - target : target - q.limit) <= target / 1000n + 1n, 'sizing stays within 0.1% of the target');
      assert.ok(calls <= 12);
      assert.ok(q.shares > 0n && q.shares <= 100000n * one);
    }
  }
});

test('sizing preserves limits on integer plateaus and near a wallet maximum', async () => {
  const quote = async shares => ({ shares, limit: ((shares + one - 1n) / one) * 100000n });
  const mint = await sizeUSDC({ mode: 'mint', target: 250000n, quote });
  assert.ok(mint.limit <= 250000n);
  const redeem = await sizeUSDC({ mode: 'redeem', target: 250000n, quote, maxShares: 3n * one });
  assert.ok(redeem.limit >= 250000n);
  assert.ok(redeem.shares <= 3n * one);
  await assert.rejects(sizeUSDC({ mode: 'redeem', target: 350000n, quote, maxShares: 3n * one }), /Insufficient M7/);
  await assert.rejects(sizeUSDC({ mode: 'redeem', target: 1n, quote, maxShares: 0n }), /No M7/);
  await assert.rejects(sizeUSDC({ mode: 'mint', target: 0n, quote }), /positive/);
  await assert.rejects(sizeUSDC({ mode: 'mint', target: 1n, quote: async () => ({ limit: 0n }) }), /too small/);
  await assert.rejects(sizeUSDC({ mode: 'mint', target: 100n, quote: async () => { throw Error('Pool unavailable'); } }), /Pool unavailable/);
});

function mockChain(t, { balance = 50n * one, poolFailure = false, age = 0, slow = false } = {}) {
  const calls = [];
  const timestamp = BigInt(Math.floor(Date.now() / 1000) - age);
  t.mock.method(client, 'getBlock', async () => ({ number: 123n, timestamp }));
  t.mock.method(client, 'readContract', async request => {
    calls.push(request);
    if (request.functionName === 'totalSupply') return 100n * one;
    if (request.functionName === 'balanceOf') return balance;
    const value = (request.args[0] * 1000000n + (request.functionName === 'quoteMint' ? one - 1n : 0n)) / one;
    return [...Array(7).fill(value), 1n];
  });
  t.mock.method(client, 'multicall', async request => {
    calls.push(request);
    if (poolFailure) throw Error('Pool unavailable');
    if (slow) t.mock.method(Date, 'now', () => Number(timestamp) * 1000 + 61000);
    return request.contracts.map(c => [c.args[0].amount ?? c.args[0].amountIn]);
  });
  return calls;
}

test('USDC quotes use one block and carry their exact safe limits into approvals and trades', async t => {
  const calls = mockChain(t);
  for (const mode of ['mint', 'redeem']) {
    const q = await quoteTrade({ mode, route: 'usdc', usdcAmount: 100000000n, account, bps: 50, key: mode });
    assert.ok(mode === 'mint' ? q.limit <= 100000000n : q.limit >= 100000000n);
    assert.equal(tradeRequest(q, account, 1000n).args[1], q.limit);
    assert.equal(approvalFor(q).amount, mode === 'mint' ? q.limit : q.shares);
    assert.equal(q.block, 123n);
    assert.ok(q.expires <= Date.now() + 60000);
  }
  assert.ok(calls.length > 4);
  assert.ok(calls.every(c => c.blockNumber === 123n));
  assert.ok(calls.every(c => c.functionName !== 'value'), 'reference prices are not used');
});

test('USDC redemption cannot exceed the wallet balance or permanently unlocked supply', async t => {
  mockChain(t);
  await assert.rejects(quoteTrade({ mode: 'redeem', route: 'usdc', usdcAmount: 400000000n, account, bps: 50, key: 'wallet' }), /Insufficient M7/);
  await assert.rejects(quoteTrade({ mode: 'redeem', route: 'usdc', usdcAmount: 700000000n, bps: 50, key: 'supply' }), /Insufficient M7/);
});

test('basket redemption stays quote-free and requires an M7 quantity', async t => {
  const calls = mockChain(t, { poolFailure: true });
  const q = await quoteTrade({ mode: 'redeem', route: 'basket', shares: one, bps: 50, key: 'basket' });
  assert.equal(q.shares, one);
  assert.equal(calls.length, 1);
  assert.equal(tradeRequest(q, account, 1000n).functionName, 'redeemBasketWithClaims');
  await assert.rejects(quoteTrade({ mode: 'redeem', route: 'basket', usdcAmount: 1000000n, bps: 50 }), /Enter M7/);
});

test('USDC sizing rejects failed pools', async t => {
  mockChain(t, { poolFailure: true });
  await assert.rejects(quoteTrade({ mode: 'mint', route: 'usdc', usdcAmount: 100000000n, bps: 50 }), /Pool unavailable/);
});

test('USDC sizing rejects stale blocks and slow quotes', async t => {
  mockChain(t, { age: 121 });
  await assert.rejects(quoteTrade({ mode: 'mint', route: 'usdc', usdcAmount: 100000000n, bps: 50 }), /old block/);
  t.mock.restoreAll();
  mockChain(t, { slow: true });
  await assert.rejects(quoteTrade({ mode: 'mint', route: 'usdc', usdcAmount: 100000000n, bps: 50 }), /took too long/);
});
