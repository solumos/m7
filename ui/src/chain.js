import { createPublicClient, fallback, http, erc20Abi, parseAbi } from 'viem';
import { base } from 'viem/chains';
import deployment from '../../deployments/base-mainnet.json' with { type: 'json' };
import config from '../../config/base.json' with { type: 'json' };
import abis from './abi.js';
import { assertFresh, bound, sizeUSDC } from './math.js';

export { base, erc20Abi, abis };
export const addresses = Object.fromEntries(Object.entries(deployment.contracts).map(([name, c]) => [name, c.address]));
export const usdc = config.usdc.address.toLowerCase();
export const stocks = config.stocks.map((s, i) => ({
  symbol: s.symbol, address: s.address.toLowerCase(), decimals: s.decimals, spacing: s.tick_spacing,
  logo: `companies/${s.symbol}.png`,
  name: ['Apple', 'Amazon', 'Alphabet', 'Meta', 'Microsoft', 'NVIDIA', 'Tesla'][i],
}));
export const assets = [...stocks, { symbol: 'USDC', address: usdc, decimals: 6, name: 'Cash' }];
export const explorer = 'https://basescan.org';
export const client = createPublicClient({
  chain: base,
  transport: fallback([http('https://base-rpc.publicnode.com', { timeout: 15000 }), http('https://mainnet.base.org', { timeout: 15000 })]),
});
const quoterAbi = parseAbi([
  'function quoteExactOutputSingle((address tokenIn, address tokenOut, uint256 amount, int24 tickSpacing, uint160 sqrtPriceLimitX96) params) returns (uint256, uint160, uint32, uint256)',
  'function quoteExactInputSingle((address tokenIn, address tokenOut, uint256 amountIn, int24 tickSpacing, uint160 sqrtPriceLimitX96) params) returns (uint256, uint160, uint32, uint256)',
]);

export function contract(name, functionName, args = []) {
  return { address: addresses[name], abi: abis[name], functionName, args };
}
export async function snapshot(account) {
  const block = await client.getBlock();
  assertFresh(block);
  const specs = [contract('M7Lens', 'value'), contract('M7Vault', 'totalSupply'),
    ...assets.map((_, i) => contract('M7Vault', 'backing', [BigInt(i)])),
    contract('IndexController', 'rebalanceDue'), contract('IndexController', 'nextTrancheAt'),
    contract('IndexController', 'currentQuarter'), contract('IndexController', 'lastExecutedQuarter'),
    ...(account ? [contract('M7Vault', 'balanceOf', [account]),
      { address: usdc, abi: erc20Abi, functionName: 'balanceOf', args: [account] },
      contract('M7Vault', 'claimOf', [account])] : [])];
  const data = await client.multicall({ contracts: specs, blockNumber: block.number });
  const get = i => data[i].status === 'success' ? data[i].result : null;
  if (get(1) === null) throw new Error('Unable to read M7 on Base. Please refresh.');
  return { block, lens: get(0), supply: get(1), backing: assets.map((_, i) => get(i + 2)),
    due: get(10), next: get(11), quarter: get(12), last: get(13),
    m7: account ? get(14) : null, usdc: account ? get(15) : null, claims: account ? get(16) : null };
}

export async function quoteTrade({ mode, route, shares, usdcAmount, account, bps, key }) {
  const block = await client.getBlock();
  assertFresh(block);
  // Every sizing attempt reads the same block, with one shared expiry.
  const expires = Math.min(Date.now() + 60000, Number(block.timestamp) * 1000 + 60000);
  const quoteShares = async shares => {
    if (expires <= Date.now()) throw new Error('The quote took too long. Please try again.');
    const amounts = await client.readContract({ ...contract('M7Vault', mode === 'mint' ? 'quoteMint' : 'quoteRedeem', [shares]), blockNumber: block.number });
    let total = amounts[7];
    if (route === 'usdc') {
      const legs = await client.multicall({ blockNumber: block.number, allowFailure: false, contracts: stocks.flatMap((s, i) => {
        if (amounts[i] === 0n) return [];
        const mint = mode === 'mint';
        return [{
          address: config.venue.quoter.toLowerCase(), abi: quoterAbi,
          functionName: mint ? 'quoteExactOutputSingle' : 'quoteExactInputSingle',
          args: [{ tokenIn: mint ? usdc : s.address, tokenOut: mint ? s.address : usdc,
            ...(mint ? { amount: amounts[i] } : { amountIn: amounts[i] }), tickSpacing: s.spacing, sqrtPriceLimitX96: 0n }],
        }];
      }) });
      total += legs.reduce((sum, v) => sum + v[0], 0n);
      if (total <= 0n) throw new Error('The pools returned no USDC for this amount.');
    }
    if (expires <= Date.now()) throw new Error('The quote took too long. Please try again.');
    return { key, mode, route, shares, bps, block: block.number, amounts, total,
      limit: bound(total, bps, mode === 'mint'), minimums: amounts.map(v => bound(v, bps)), expires };
  };
  if (usdcAmount == null) return quoteShares(shares);
  if (route !== 'usdc') throw new Error('Enter M7 for an underlying basket redemption.');
  let maxShares;
  if (mode === 'redeem') {
    // M7Vault permanently locks 10 M7; quoteRedeem excludes those shares.
    const supply = await client.readContract({ ...contract('M7Vault', 'totalSupply'), blockNumber: block.number });
    maxShares = supply - 10n ** 19n;
    if (account) {
      const balance = await client.readContract({ ...contract('M7Vault', 'balanceOf', [account]), blockNumber: block.number });
      if (balance < maxShares) maxShares = balance;
    }
  }
  return sizeUSDC({ mode, target: usdcAmount, quote: quoteShares, maxShares });
}

export const tradeRequest = (q, account, deadline) => q.mode === 'mint'
  ? contract('USDCGateway', 'mintWithUSDC', [q.shares, q.limit, account, deadline])
  : q.route === 'usdc'
    ? contract('USDCGateway', 'redeemToUSDC', [q.shares, q.limit, account, deadline])
    : contract('M7Vault', 'redeemBasketWithClaims', [q.shares, q.minimums, account, deadline]);

export function approvalFor(q) {
  return q.mode === 'mint' ? { token: usdc, amount: q.limit, symbol: 'USDC', decimals: 6 }
    : q.route === 'usdc' ? { token: addresses.M7Vault, amount: q.shares, symbol: 'M7', decimals: 18 } : null;
}
