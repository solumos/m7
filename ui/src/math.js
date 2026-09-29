import { parseUnits, maxUint256 } from 'viem';

export function amount(text, decimals = 18) {
  if (!new RegExp(`^\\d+(?:\\.\\d{1,${decimals}})?$`).test(text)) {
    throw new Error(`Enter a positive amount with at most ${decimals} decimal places.`);
  }
  const value = parseUnits(text, decimals);
  if (value <= 0n || value > maxUint256) throw new Error('Amount is outside the supported range.');
  return value;
}

export function bound(value, bps, up = false) {
  if (![10, 50, 100].includes(bps)) throw new Error('Choose a supported slippage limit.');
  const result = up ? (value * BigInt(10000 + bps) + 9999n) / 10000n : value * BigInt(10000 - bps) / 10000n;
  if (result > maxUint256) throw new Error('Amount exceeds the supported range.');
  return result;
}

// Size exact M7 transactions from executable, slippage-adjusted USDC quotes.
// Every returned quote must respect the budget/minimum, including rounding.
export async function sizeUSDC({ mode, target, quote, maxShares = maxUint256 }) {
  if (target <= 0n || target > maxUint256) throw new Error('Enter a positive USDC amount.');
  if (maxShares <= 0n) throw new Error('No M7 is available to redeem.');
  const mint = mode === 'mint';
  const tolerance = target / 10000n || 1n;
  let low = 0n, high = maxShares + 1n, best, previous;
  let shares = maxShares < 10n ** 18n ? maxShares : 10n ** 18n;
  for (let attempt = 0; attempt < 12; attempt++) {
    const q = await quote(shares);
    if (q.limit <= 0n) throw new Error('This amount is too small for a USDC quote. Try entering M7.');
    if (q.limit === target) return q;
    if (q.limit < target) {
      low = shares;
      if (mint) best = q;
      if (mint && target - q.limit <= tolerance) return q;
      if (shares === maxShares) {
        if (mint) return q;
        throw new Error('Insufficient M7 for this USDC amount. Use Max to redeem your balance.');
      }
    } else {
      high = shares;
      if (!mint) best = q;
      if (!mint && q.limit - target <= tolerance) return q;
    }
    if (high - low <= 1n) break;
    // Start with a ratio, then use the observed price slope. Brackets handle
    // nonlinear impact and integer plateaus without accepting an unsafe limit.
    let next = (shares * target + (mint ? 0n : q.limit - 1n)) / q.limit;
    if (previous && q.limit !== previous.limit) {
      next = shares + (target - q.limit) * (shares - previous.shares) / (q.limit - previous.limit);
    }
    if (next > maxShares) next = maxShares;
    if (next <= low || next >= high) next = high <= maxShares ? (low + high) / 2n : (low * 2n > maxShares ? maxShares : low * 2n);
    if (next <= low || next >= high) break;
    previous = q;
    shares = next;
  }
  if (best) return best;
  throw new Error('Unable to size this USDC amount. Try entering M7 instead.');
}

export function inWindow(timestamp) {
  const d = new Date(Number(timestamp) * 1000);
  return d.getUTCDay() >= 1 && d.getUTCDay() <= 5 && d.getUTCHours() >= 15 && d.getUTCHours() < 20;
}

export function assertQuote(quote, key, now = Date.now()) {
  if (!quote || quote.key !== key) throw new Error('Your inputs or wallet changed. Get a new quote.');
  if (now >= quote.expires) throw new Error('This quote expired. Get a new quote before continuing.');
}

export function assertFresh(block, now = Date.now()) {
  if (Math.abs(now / 1000 - Number(block.timestamp)) > 120) {
    throw new Error('The RPC returned an old block, or your device clock is incorrect. Refresh before continuing.');
  }
}
