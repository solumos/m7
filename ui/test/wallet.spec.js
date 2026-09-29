import { test, expect } from '@playwright/test';
import { decodeFunctionData, encodeFunctionResult, erc20Abi, multicall3Abi, parseAbi } from 'viem';
import { addresses, abis } from '../src/chain.js';

const account = '0x1111111111111111111111111111111111111111';
const blockHash = `0x${'ab'.repeat(32)}`;
const quoter = parseAbi(['function quoteExactOutputSingle((address,address,uint256,int24,uint160)) returns(uint256,uint160,uint32,uint256)', 'function quoteExactInputSingle((address,address,uint256,int24,uint160)) returns(uint256,uint160,uint32,uint256)']);
const allAbi = [...Object.values(abis).flat(), ...erc20Abi, ...quoter];
const hex = v => `0x${BigInt(v).toString(16)}`;

async function setup(page, options = {}) {
  const sent = [], allowances = new Map(), transactions = new Map();
  const claims = options.claims || Array(8).fill(0n);
  const block = () => ({ number: hex(52000000), timestamp: hex(Math.floor(Date.now() / 1000)), hash: blockHash, parentHash: blockHash, gasLimit: '0x3938700', gasUsed: '0x0', baseFeePerGas: '0x1', transactions: [] });
  function call(data, to) {
    const { functionName: fn, args } = decodeFunctionData({ abi: allAbi, data });
    let result;
    if (fn === 'value') {
      if (options.lensFailure) throw Error('Oracle unavailable');
      result = { perShare: 125000000000000000n, nav: 125n * 10n ** 18n, supply: 1000n * 10n ** 18n,
        components: [...Array(7).fill(125n * 10n ** 18n / 7n), 0n], oldestPriceAt: BigInt(Math.floor(Date.now() / 1000) - 60), issuerPaused: false, sequencerDown: false };
    } else if (fn === 'totalSupply') result = 1000n * 10n ** 18n;
    else if (fn === 'backing') result = args[0] === 7n ? 0n : 5000000n;
    else if (fn === 'rebalanceDue') result = true;
    else if (fn === 'nextTrancheAt') result = 0n;
    else if (fn === 'currentQuarter') result = 8106;
    else if (fn === 'lastExecutedQuarter') result = 0;
    else if (fn === 'claimOf') result = claims;
    else if (fn === 'balanceOf') result = to.toLowerCase() === addresses.M7Vault ? 990n * 10n ** 18n : 100n * 10n ** 6n;
    else if (fn === 'allowance') result = allowances.get(to.toLowerCase()) || 0n;
    else if (fn === 'quoteMint' || fn === 'quoteRedeem') result = [...Array(7).fill(1000000n), 0n];
    else if (fn.startsWith('quoteExact')) { if (options.quoteFailure) throw Error('Pool unavailable'); result = [1000000n, 1n, 0, 100000n]; }
    else if (fn === 'approve') result = true;
    else if (fn === 'mintWithUSDC' || fn === 'redeemToUSDC') result = 7000000n;
    else if (fn === 'redeemBasketWithClaims') result = [Array(8).fill(100n), Array(8).fill(0n)];
    else if (fn === 'snapshot') result = Array(8).fill(10n ** 18n);
    return encodeFunctionResult({ abi: allAbi, functionName: fn, result });
  }
  await page.route('**/__wallet-transaction', async route => {
    const tx = route.request().postDataJSON();
    const decoded = decodeFunctionData({ abi: allAbi, data: tx.data });
    sent.push({ ...tx, ...decoded });
    if (decoded.functionName === 'approve' && !options.reverted) allowances.set(tx.to.toLowerCase(), decoded.args[1]);
    const hash = `0x${sent.length.toString(16).padStart(64, '0')}`;
    transactions.set(hash, { ...tx, hash, blockHash, blockNumber: hex(52000000), transactionIndex: '0x0', value: '0x0', nonce: hex(sent.length - 1), gasPrice: '0x1', type: '0x0', input: tx.data });
    await route.fulfill({ json: { hash } });
  });
  await page.route(/https:\/\/(base-rpc\.publicnode\.com|mainnet\.base\.org)/, async route => {
    const rpc = request => {
      let result;
      try {
        const { method, params = [] } = request;
        if (method === 'eth_chainId') result = '0x2105';
        else if (method === 'eth_blockNumber') result = hex(52000000);
        else if (method === 'eth_getBlockByNumber') result = block();
        else if (method === 'eth_estimateGas') result = '0x30d40';
        else if (method === 'eth_getTransactionByHash') result = transactions.get(params[0]) || null;
        else if (method === 'eth_getTransactionReceipt') {
          const tx = transactions.get(params[0]);
          result = tx ? { transactionHash: tx.hash, transactionIndex: '0x0', blockHash, blockNumber: hex(52000000), from: account, to: tx.to, cumulativeGasUsed: '0x1234', gasUsed: '0x1234', contractAddress: null, logs: [], logsBloom: `0x${'00'.repeat(256)}`, status: options.reverted ? '0x0' : '0x1', effectiveGasPrice: '0x1', type: '0x0' } : null;
        } else if (method === 'eth_call') {
          const { data, to } = params[0];
          if (to.toLowerCase() === '0xca11bde05977b3631167028862be2a173976ca11') {
            const { args } = decodeFunctionData({ abi: multicall3Abi, data });
            result = encodeFunctionResult({ abi: multicall3Abi, functionName: 'aggregate3', result: args[0].map(c => { try { return { success: true, returnData: call(c.callData, c.target) }; } catch { return { success: false, returnData: '0x' }; } }) });
          } else result = call(data, to);
        } else throw Error(`Unexpected RPC ${method}`);
        return { jsonrpc: '2.0', id: request.id, result };
      } catch (e) { return { jsonrpc: '2.0', id: request.id, error: { code: -32000, message: e.message } }; }
    };
    const input = route.request().postDataJSON();
    await route.fulfill({ json: Array.isArray(input) ? input.map(rpc) : rpc(input) });
  });
  await page.addInitScript(({ account, wrongChain, rejected }) => {
    const handlers = {};
    window.mockWallet = { account, chain: wrongChain ? '0x1' : '0x2105',
      on: (name, fn) => { (handlers[name] ||= new Set()).add(fn); },
      removeListener: (name, fn) => handlers[name]?.delete(fn),
      emit: (name, value) => { if (name === 'accountsChanged') window.mockWallet.account = value[0]; for (const fn of handlers[name] || []) fn(value); },
      request: async ({ method, params }) => {
        if (method === 'eth_accounts' || method === 'eth_requestAccounts') return [window.mockWallet.account];
        if (method === 'eth_chainId') return window.mockWallet.chain;
        if (method === 'wallet_switchEthereumChain') { window.mockWallet.chain = params[0].chainId; window.mockWallet.emit('chainChanged', params[0].chainId); return null; }
        if (method === 'wallet_watchAsset') { (window.watchedAssets ||= []).push(params); return true; }
        if (method === 'eth_sendTransaction') {
          if (rejected) { const e = new Error('User rejected'); e.code = 4001; throw e; }
          const result = await fetch('/__wallet-transaction', { method: 'POST', body: JSON.stringify(params[0]) }).then(r => r.json()); return result.hash;
        }
        throw new Error(`Unexpected wallet request ${method}`);
      },
    };
    window.ethereum = window.mockWallet;
  }, { account, wrongChain: options.wrongChain, rejected: options.rejected });
  await page.goto('/');
  if (!options.noticeOnly) {
    await page.locator('#risk-eligible').check();
    await page.locator('#risk-understood').check();
    await page.locator('#risk-continue').click();
  }
  await expect(page.locator('#connection')).toContainText('Block');
  return sent;
}

async function connectAndQuote(page, redeem = false, basket = false) {
  await page.getByRole('button', { name: 'Connect wallet', exact: true }).click();
  await expect(page.locator('#position')).toHaveText('990 M7');
  if (redeem) await page.locator('#redeem-tab').click();
  if (basket) await page.locator('#route').selectOption('basket');
  if (!basket) await page.locator('#amount-unit').selectOption('m7');
  await page.locator('#amount').fill('10');
  await page.locator('#quote').click();
  await expect(page.locator('#review')).toBeVisible();
}

test('risk acknowledgment gates wallet access, survives reload, and can return to view-only', async ({ page }) => {
  const sent = await setup(page, { noticeOnly: true });
  const notice = page.locator('#risk-dialog'), proceed = page.locator('#risk-continue');
  await expect(notice).toBeVisible();
  await expect(proceed).toBeDisabled();
  await page.locator('#risk-eligible').check();
  await expect(proceed).toBeDisabled();
  await page.keyboard.press('Escape');
  await expect(notice).not.toBeVisible();
  await expect(page.locator('#access-note')).toBeVisible();
  await page.locator('#connect').click();
  await expect(notice).toBeVisible();
  await expect(page.locator('#risk-eligible')).not.toBeChecked();
  await expect(page.locator('#wallet-dialog')).not.toBeVisible();
  await page.locator('#risk-eligible').check();
  await page.locator('#risk-understood').check();
  await expect(proceed).toBeEnabled();
  await page.locator('#risk-eligible').uncheck();
  await expect(proceed).toBeDisabled();
  await page.locator('#risk-eligible').check();
  await proceed.click();
  await expect(notice).not.toBeVisible();
  await page.reload();
  await expect(notice).not.toBeVisible();
  await page.locator('#connect').click();
  await expect(page.locator('#position')).toHaveText('990 M7');
  await page.locator('#risk-open').click();
  await page.locator('#risk-browse').click();
  await expect(page.locator('#disconnect')).toBeHidden();
  await expect(page.locator('#access-note')).toBeVisible();
  await page.locator('#connect').click();
  await expect(notice).toBeVisible();
  expect(sent).toHaveLength(0);
});

test('mint uses exact capped approval, a separate confirmation, and the reviewed USDC limit', async ({ page }) => {
  const sent = await setup(page);
  await connectAndQuote(page);
  await expect(page.locator('#quote-details')).toContainText('7.035 USDC');
  await page.locator('#review').click();
  await expect(page.locator('#review-title')).toHaveText('Approve USDC');
  await page.locator('#confirm').click();
  await expect(page.locator('#activity')).toContainText('USDC approval confirmed');
  expect(sent).toHaveLength(1);
  expect(sent[0].args[0].toLowerCase()).toBe(addresses.USDCGateway);
  expect(sent[0].args[1]).toBe(7035000n);
  await page.locator('#quote').click();
  await page.locator('#review').click();
  await expect(page.locator('#review-title')).toHaveText('Mint');
  await page.locator('#confirm').click();
  await expect(page.locator('#activity')).toContainText('M7 mint confirmed');
  expect(sent[1].to.toLowerCase()).toBe(addresses.USDCGateway);
  expect(sent[1].functionName).toBe('mintWithUSDC');
  expect(sent[1].args.slice(0, 3)).toEqual([10n ** 19n, 7035000n, account]);
});

test('USDC redemption approves shares and sends a nonzero minimum proceeds limit', async ({ page }) => {
  const sent = await setup(page);
  await connectAndQuote(page, true);
  await page.locator('#review').click();
  await expect(page.locator('#review-title')).toHaveText('Approve M7');
  await page.locator('#confirm').click();
  await expect(page.locator('#activity')).toContainText('M7 approval confirmed');
  expect(sent[0].to.toLowerCase()).toBe(addresses.M7Vault);
  expect(sent[0].args[1]).toBe(10n ** 19n);
  await page.locator('#quote').click();
  await page.locator('#review').click();
  await page.locator('#confirm').click();
  await expect(page.locator('#activity')).toContainText('M7 redemption confirmed');
  expect(sent[1].functionName).toBe('redeemToUSDC');
  expect(sent[1].args[1]).toBe(6965000n);
});

test('direct basket exit works without an oracle, pool quote or approval', async ({ page }) => {
  const sent = await setup(page, { lensFailure: true, quoteFailure: true });
  await connectAndQuote(page, true, true);
  await expect(page.locator('#price')).toHaveText('—');
  await page.locator('#review').click();
  await expect(page.locator('#review-body')).toContainText('reserved as a claim');
  await page.locator('#confirm').click();
  await expect(page.locator('#activity')).toContainText('M7 redemption confirmed');
  expect(sent).toHaveLength(1);
  expect(sent[0].functionName).toBe('redeemBasketWithClaims');
  expect(sent[0].args[1][0]).toBe(995000n);
});

test('account changes discard a reviewed transaction and expired quotes disable signing', async ({ page }) => {
  const sent = await setup(page);
  await connectAndQuote(page);
  await page.locator('#review').click();
  await page.evaluate(() => window.mockWallet.emit('accountsChanged', ['0x2222222222222222222222222222222222222222']));
  await expect(page.locator('#review-dialog')).not.toBeVisible();
  await expect(page.locator('#review')).not.toBeVisible();
  expect(sent).toHaveLength(0);
  await page.locator('#quote').click();
  await expect(page.locator('#review')).toBeEnabled();
  await page.clock.install();
  await page.clock.fastForward(61000);
  await expect(page.locator('#review')).toBeDisabled();
});

test('a reverted approval is reported as failed, never successful', async ({ page }) => {
  await setup(page, { reverted: true });
  await connectAndQuote(page);
  await page.locator('#review').click();
  await page.locator('#confirm').click();
  await expect(page.locator('#activity')).toContainText('transaction reverted');
  await expect(page.locator('#activity')).not.toContainText('confirmed');
});

test('wallet rejection sends nothing and a wrong network cannot transact', async ({ page }) => {
  const sent = await setup(page, { wrongChain: true, rejected: true });
  await connectAndQuote(page);
  await page.locator('#review').click();
  await expect(page.locator('#activity')).toContainText('Switch your wallet to Base');
  expect(sent).toHaveLength(0);
  await page.locator('#add-token').click();
  expect(await page.evaluate(() => window.watchedAssets || [])).toEqual([]);
  await page.locator('#connect').click();
  await page.locator('#quote').click();
  await page.locator('#review').click();
  await page.locator('#confirm').click();
  await expect(page.locator('#activity')).toContainText('canceled in your wallet');
  expect(sent).toHaveLength(0);
  await page.locator('#close-review').click();
  await page.locator('#add-token').click();
  await expect(page.locator('#activity')).toContainText('M7 added to your wallet.');
  const [asset] = await page.evaluate(() => window.watchedAssets);
  expect(asset).toEqual({ type: 'ERC20', options: { address: addresses.M7Vault, symbol: 'M7', decimals: 18, image: 'http://127.0.0.1:5173/token-icon.png' } });
  const icon = await page.request.get(asset.options.image);
  expect(icon.ok()).toBe(true);
  expect(icon.headers()['content-type']).toContain('image/png');
});

test('claims use the reviewed recipient; the mobile page fits the viewport', async ({ page }) => {
  const sent = await setup(page, { claims: [123n, ...Array(7).fill(0n)] });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('#connect').click();
  const recipient = '0x2222222222222222222222222222222222222222';
  await page.locator('#claim-recipient').fill(recipient);
  await page.locator('[data-claim="0"]').click();
  await expect(page.locator('#review-body')).toContainText(recipient);
  await page.locator('#confirm').click();
  await expect(page.locator('#activity')).toContainText('AAPLc withdrawal confirmed');
  expect(sent[0].functionName).toBe('withdrawClaim');
  expect(sent[0].args).toEqual([0n, 123n, recipient]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});
