import './style.css';
import { createWalletClient, custom, formatUnits, isAddress, zeroAddress } from 'viem';
import { addresses, assets, base, client, contract, erc20Abi, explorer, usdc, snapshot, quoteTrade, tradeRequest, approvalFor } from './chain.js';
import { amount, assertFresh, assertQuote, inWindow } from './math.js';

const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const short = s => `${s.slice(0, 6)}…${s.slice(-4)}`;
const units = (v, d = 18, precision = 4) => v == null ? '—' : Number(formatUnits(v, d)).toLocaleString('en-US', { maximumFractionDigits: precision });
const exact = (v, d = 18) => formatUnits(v, d);
const dollars = (v, precision = 2) => v == null ? '—' : `$${units(v, 18, precision)}`;
const when = timestamp => new Date(Number(timestamp) * 1000).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const link = (address, label = short(address)) => `<a href="${explorer}/address/${address}" target="_blank" rel="noreferrer">${esc(label)}</a>`;
const state = { account: null, provider: null, chain: null, session: 0, data: null, quote: null, busy: false, loading: false, mode: 'mint', prepared: null };
const providers = new Map();
const riskNoticeKey = 'm7-risk-notice-v1';
let riskAccepted = false;
try { riskAccepted = sessionStorage.getItem(riskNoticeKey) === 'accepted'; } catch { /* Storage may be blocked; acknowledgment still works for this page. */ }

$('app').innerHTML = `
  <header class="header wrap">
    <a href="#" class="brand" aria-label="M7 home"><img src="./favicon.svg" alt="" width="32" height="32"></a>
    <nav aria-label="Main"><a href="#use">Mint &amp; redeem</a><a href="#compare">Compare fees</a><a href="#protocol">How it works</a></nav>
    <div class="wallet-nav"><span class="base">Base</span><button id="connect" class="dark">Connect wallet</button><button id="disconnect" class="text-button" hidden>Disconnect</button></div>
  </header>
  <main id="main" class="wrap">
    <section class="hero" id="overview">
      <div class="hero-copy">
      <h1><span class="hero-line">MAG7 Index</span> <span class="hero-line">Equal Weighting</span> <span class="hero-line">No Management Fee</span></h1>
      <p class="intro">M7 is designed to track an equal-weight basket of the seven Magnificent Seven stocks through tokenized assets on Base.</p>
      <p class="fine">Trading costs, gas, and basket reset costs still apply.</p>
      </div>
      <img class="seven-mark" src="./seven-mark.svg" alt="" width="288" height="224" aria-hidden="true">
    </section>
    <div class="connection-line"><span id="connection" role="status">Reading Base…</span><button class="text-button" id="refresh">Refresh</button></div>
    <div id="read-error" class="notice error" role="alert" hidden></div>
    <p id="access-note" class="fine" role="status" hidden>Viewing only. Select Connect wallet to review eligibility and risks before transacting.</p>
    <div class="workspace">
      <section class="trade" id="use" aria-labelledby="trade-title">
        <h2 id="trade-title" class="sr-only">Mint</h2>
        <div id="position-summary" hidden><div class="position-line"><span id="position"></span><button class="text-button" id="add-token" title="Add M7 and its icon to your wallet" hidden>Add M7</button></div><p id="position-value" class="fine"></p></div>
        <div class="tabs" aria-label="Transaction type"><button id="mint-tab" aria-pressed="true">Mint</button><button id="redeem-tab" aria-pressed="false">Redeem</button></div>
        <div id="route-field" class="field" hidden><label for="route">Receive</label><select id="route"><option value="usdc">USDC</option><option value="basket">Underlying basket</option></select></div>
        <div class="amount-box">
          <div class="amount-heading"><label for="amount" id="amount-label">USDC budget</label><button id="max" class="text-button" disabled>Max</button></div>
          <div class="amount-entry"><input id="amount" inputmode="decimal" autocomplete="off" placeholder="0.00" aria-describedby="amount-help balance"><select id="amount-unit" aria-label="Amount currency"><option value="usdc">USDC</option><option value="m7">M7</option></select></div>
          <p class="fine" id="balance">Connect your wallet to see balances</p>
        </div>
        <p class="fine amount-help" id="amount-help">Your budget includes the slippage allowance. Max uses your USDC balance.</p>
        <div class="slippage"><label for="slippage">Slippage limit</label><select id="slippage"><option value="10">0.1%</option><option value="50" selected>0.5%</option><option value="100">1.0%</option></select></div>
        <button id="quote" class="primary full">Preview mint</button>
        <div id="quote-details" class="quote-details" hidden></div>
        <button id="review" class="primary full" hidden>Review transaction</button>
        <p id="trade-note" class="fine">Pay USDC for an exact amount of M7. Preview your cost before approving or signing. Pool fees are included; gas is additional.</p>
        <p class="fine" id="network-note" hidden>Switch your wallet to Base to transact.</p>
      </section>
      <section class="basket" aria-labelledby="basket-title">
        <h2 id="basket-title">The basket</h2>
        <div class="metrics" aria-label="Basket statistics">
          <div><span class="label">Reference value / M7</span><strong id="price">—</strong></div>
          <div><span class="label">Total backing</span><strong id="nav">—</strong></div>
          <div><span class="label">M7 supply</span><strong id="supply">—</strong></div>
        </div>
        <div class="table-wrap" role="region" aria-label="Basket holdings" tabindex="0"><table><thead><tr><th scope="col">Asset</th><th scope="col">Quantity</th><th scope="col">Value</th><th scope="col">Weight</th></tr></thead><tbody id="assets"></tbody></table></div>
        <p class="fine basket-foot">Target: 1/7 (14.29%) per stock, reset quarterly. Actual weights drift; exact tracking is not guaranteed. Backing excludes deferred claims. Supply includes 10 permanently locked M7.</p>
        <p id="price-note" class="fine">Reading reference prices…</p>
      </section>
    </div>
    <section id="claims-card" class="claims" aria-labelledby="claims-title" hidden>
      <h2 id="claims-title">Deferred withdrawals</h2>
      <p class="fine">If a basket redemption cannot deliver an asset, it stays reserved for you. Withdrawal requires the issuer to permit the transfer. You may choose another eligible recipient.</p>
      <label for="claim-recipient">Recipient address <span class="fine">(defaults to your wallet)</span></label><input id="claim-recipient" class="address-input" autocomplete="off" spellcheck="false" placeholder="0x…">
      <div id="claims"></div>
    </section>
    <section class="comparison" id="compare" aria-labelledby="compare-title">
      <h2 id="compare-title">Compare management fees</h2>
      <div class="table-wrap" role="region" aria-label="Management fee comparison" tabindex="0">
        <table class="comparison-table">
          <caption class="sr-only">Published ongoing charges, checked September 28, 2026. These are different product structures, not total-cost equivalents.</caption>
          <thead><tr><th scope="col">Product</th><th scope="col">Annual management fee</th><th scope="col">Structure &amp; control</th></tr></thead>
          <tbody>
            <tr><th scope="row">M7</th><td><strong class="fee">0%</strong><span>No management fee</span></td><td>Token basket on Base. Fixed rules, no administrator or upgrade key. Quarterly reset target.</td></tr>
            <tr><th scope="row"><a href="https://app.reserve.org/base/index-dtf/0xcef8db49e456f872e288e1c042f916e9ced7c781/overview" target="_blank" rel="noreferrer">Reserve MAG7</a></th><td><strong class="fee">0.60%</strong><span>Annualized TVL fee</span></td><td>DTF on Base with onchain governance and assigned roles. Mandate: rebalance every two months.</td></tr>
            <tr><th scope="row"><a href="https://www.roundhillinvestments.com/etf/mags/" target="_blank" rel="noreferrer">Roundhill MAGS</a></th><td><strong class="fee">0.29%</strong><span>0.30% total annual expenses</span></td><td>Actively managed ETF, traded through a broker. Quarterly equal-weight rebalance.</td></tr>
          </tbody>
        </table>
      </div>
      <p class="fine">Ongoing charges only, not total costs or equivalent risk. M7 users pay pool fees, price impact, and gas when transacting. Basket resets incur trading costs and pay the caller 0.05% of one-way traded value, capped at $25 per tranche, from the basket. Underlying asset costs can also affect returns. Reserve additionally lists a 0.30% minting fee; brokerage costs and spreads can apply to MAGS.</p>
      <p class="fine sources">Checked September 28, 2026. Sources: <a href="${explorer}/address/${addresses.M7Vault}#code" target="_blank" rel="noreferrer">M7 vault</a>, <a href="${explorer}/address/${addresses.IndexController}#code" target="_blank" rel="noreferrer">reset controller</a>, <a href="https://app.reserve.org/base/index-dtf/0xcef8db49e456f872e288e1c042f916e9ced7c781/settings" target="_blank" rel="noreferrer">Reserve fees &amp; roles</a>, <a href="https://www.roundhillinvestments.com/assets/pdfs/MAGS_Summary_Prospectus.pdf" target="_blank" rel="noreferrer">MAGS prospectus</a>. Published fees may change.</p>
    </section>
    <section class="protocol" id="protocol" aria-labelledby="protocol-title">
      <h2 id="protocol-title">How M7 works</h2>
      <div class="protocol-grid">
        <div class="explanation">
          <h3>Mint and redeem from your wallet</h3><p>Pay USDC to mint M7. Redeem to USDC or take your share of the underlying tokens. No M7 exchange pool is required. If an approval is needed, it is a separate transaction; preview again after it confirms.</p>
          <h3>Reference values and trade quotes</h3><p>Reference values use price feeds. Your trade quote uses the actual pools and order size. Review your maximum spend or minimum receipt before signing.</p>
          <h3>Fixed rules have tradeoffs</h3><p>No administrator can change M7’s contracts or repair them in place. Stock issuers can restrict transfers, freeze, or seize tokens. Price feeds, liquidity pools, and Base remain dependencies. M7 has not had an independent audit and is offered without warranty under the Unlicense.</p>
        </div>
        <details class="reset-details"><summary>Quarterly basket reset <span id="reset-badge">Reading status</span></summary><div class="reset-content"><p>Anyone can execute an eligible tranche. The contract decides the trades and enforces its limits.</p><dl><div><dt>Execution window</dt><dd>Weekdays, 15:00–20:00 UTC</dd></div><div><dt>Caller reward</dt><dd>0.05% of traded value, up to $25 per tranche</dd></div></dl><p id="reset-status" class="fine">Reading the reset schedule…</p><button id="reset" class="secondary full" disabled>Review next tranche</button></div></details>
      </div>
    </section>
    <details class="contracts"><summary>Deployed contracts · Base mainnet</summary><div>${Object.entries(addresses).map(([name, address]) => `<div><span>${esc(name)}</span>${link(address)}</div>`).join('')}</div></details>
    <footer><span>M7 · Magnificent Seven</span><div><button id="risk-open" class="text-button">Eligibility &amp; risks</button><a href="./LICENSE.txt" target="_blank" rel="noreferrer">Unlicense</a><a href="./THIRD_PARTY_NOTICES.txt" target="_blank" rel="noreferrer">Notices</a><a href="${explorer}/token/${addresses.M7Vault}" target="_blank" rel="noreferrer">Token tracker</a></div></footer>
  </main>
  <div id="activity" class="activity" role="status" aria-live="polite" hidden></div>
  <dialog id="wallet-dialog"><div class="dialog-top"><h2>Connect a wallet</h2><button class="text-button" data-close="wallet-dialog" aria-label="Close">Close</button></div><p class="fine">Use a browser wallet on this device. Your keys stay in your wallet.</p><div id="wallet-list"></div></dialog>
  <dialog id="review-dialog"><div class="dialog-top"><h2 id="review-title">Review transaction</h2><button class="text-button" id="close-review" data-close="review-dialog" aria-label="Close">Close</button></div><div id="review-body"></div><p class="fine">Network fees are paid in ETH on Base. Check the destination and amounts in your wallet before signing.</p><button id="confirm" class="primary full">Confirm in wallet</button></dialog>
  <dialog id="risk-dialog" aria-labelledby="risk-title" aria-describedby="risk-intro">
    <h2 id="risk-title" tabindex="-1" autofocus>Before you use M7</h2>
    <p id="risk-intro" class="risk-intro">Use at your own risk.</p>
    <div class="risk-copy">
      <h3>Not available in the United States</h3>
      <p>This product is not available to users located in the United States. Do not use this interface where prohibited by law.</p>
      <h3>Unaudited smart contracts</h3>
      <p>M7’s smart contracts have not undergone an independent security audit. <strong>You could permanently lose all funds you commit.</strong> Bugs, exploits, market movements, issuer restrictions, or failures of price feeds, liquidity pools, or Base may cause losses or prevent withdrawals.</p>
      <h3>No warranties or guarantees</h3>
      <p>The software is provided “as is” and “as available,” without warranties. Returns, index tracking, liquidity, and recovery of funds are not guaranteed. Nothing here is financial, investment, legal, or tax advice. Only commit funds you can afford to lose. <a href="./LICENSE.txt" target="_blank" rel="noreferrer">Read the Unlicense</a>.</p>
    </div>
    <form id="risk-form">
      <label class="risk-check"><input id="risk-eligible" type="checkbox" required><span>I am not located in the United States, and my use is permitted where I live.</span></label>
      <label class="risk-check"><input id="risk-understood" type="checkbox" required><span>I understand the risks, including total loss of funds, and use M7 at my own risk.</span></label>
      <button id="risk-continue" class="primary full" type="submit" disabled>Acknowledge and continue</button>
      <button id="risk-browse" class="text-button full" type="button">View site only</button>
    </form>
  </dialog>
`;

function showRiskNotice() {
  $('risk-form').reset();
  $('risk-continue').disabled = true;
  if (!$('risk-dialog').open) $('risk-dialog').showModal();
}
function requireRiskAcknowledgment() {
  if (riskAccepted) return true;
  showRiskNotice();
  return false;
}
$('risk-form').onchange = () => { $('risk-continue').disabled = !$('risk-eligible').checked || !$('risk-understood').checked; };
$('risk-form').onsubmit = event => {
  event.preventDefault();
  if (!$('risk-eligible').checked || !$('risk-understood').checked) return;
  riskAccepted = true;
  try { sessionStorage.setItem(riskNoticeKey, 'accepted'); } catch { /* Keep the in-memory acknowledgment. */ }
  $('risk-dialog').close();
};
$('risk-browse').onclick = () => {
  riskAccepted = false;
  try { sessionStorage.removeItem(riskNoticeKey); } catch { /* Storage is optional. */ }
  clearQuote();
  if (state.account) disconnect();
  $('risk-dialog').close();
};
$('risk-dialog').addEventListener('close', () => { $('access-note').hidden = riskAccepted; });
$('risk-open').onclick = showRiskNotice;

function report(message, hash, error = false) {
  $('activity').hidden = false;
  $('activity').classList.toggle('error', error);
  $('activity').replaceChildren(document.createTextNode(message));
  if (hash) {
    const a = document.createElement('a');
    a.href = `${explorer}/tx/${hash}`; a.target = '_blank'; a.rel = 'noreferrer'; a.textContent = 'View transaction';
    $('activity').append(a);
  }
  const close = document.createElement('button');
  close.className = 'dismiss'; close.setAttribute('aria-label', 'Dismiss message'); close.textContent = 'Close';
  close.onclick = () => { $('activity').hidden = true; };
  $('activity').append(close);
}

function errorText(error) {
  const revert = error.walk?.(e => e.data?.errorName)?.data?.errorName;
  const messages = { OutsideExecutionWindow: 'Resets open on weekdays from 15:00 to 20:00 UTC.', TooSoon: 'The next reset tranche is still in its cooldown.',
    AlreadyRebalanced: 'This quarter’s reset is complete.', NoFreshMarketSignal: 'The reset needs a more recent market price.',
    SequencerUnavailable: 'Base’s sequencer safety check is not ready.', PoolMoved: 'A pool moved outside the reset’s price guard. Try later.',
    PoolUnavailable: 'A required pool is unavailable.', UnavailablePrice: 'A required price feed is unavailable or stale.',
    CorporateAction: 'An issuer’s price is paused for a corporate action.', PolicyForbidden: 'The stock issuer does not permit this wallet or transfer.',
    PolicyUnavailable: 'The issuer’s transfer policy could not be checked.', InsufficientProceeds: 'Proceeds fell below your minimum. Get a new quote.',
    InsufficientUSDC: 'The purchase exceeds the USDC limit. Get a new quote.', OutputLimit: 'Basket quantities changed beyond your limit. Get a new quote.',
    MissingComponent: 'The basket cannot support this mint amount.', InsufficientLockedBacking: 'This amount would breach the contract’s minimum backing.',
    Expired: 'The transaction deadline passed. Get a new quote.', DeadlineExpired: 'The transaction deadline passed. Get a new quote.' };
  if (messages[revert]) return messages[revert];
  if (error.code === 4001 || /rejected|denied by user/i.test(error.shortMessage || error.message)) return 'Request canceled in your wallet.';
  return (error.shortMessage || error.message || 'The request failed. Please try again.').slice(0, 420);
}

function key() { return [state.session, state.account, state.mode, route(), $('amount-unit').value, $('amount').value, $('slippage').value].join(':'); }
function route() { return state.mode === 'mint' ? 'usdc' : $('route').value; }
function clearQuote() { state.quote = null; state.prepared = null; $('quote-details').hidden = true; $('review').hidden = true; }
function setBusy(busy) {
  state.busy = busy;
  ['amount', 'slippage', 'route', 'mint-tab', 'redeem-tab', 'quote', 'review', 'confirm', 'connect', 'disconnect', 'close-review', 'claim-recipient', 'risk-open'].forEach(id => $(id).disabled = busy);
  document.querySelectorAll('[data-claim]').forEach(el => el.disabled = busy);
  renderAmount();
  renderReset();
}

function renderAmount() {
  const mint = state.mode === 'mint', dollars = $('amount-unit').value === 'usdc';
  $('amount-label').textContent = dollars ? mint ? 'USDC budget' : 'USDC to receive' : mint ? 'M7 to receive' : 'M7 to redeem';
  $('amount-help').textContent = route() === 'basket' ? 'Enter M7 to receive the underlying basket. Max uses your M7 balance.'
    : dollars ? mint ? 'Your budget includes the slippage allowance. Max uses your USDC balance.' : 'Set the minimum USDC to receive. Max switches to your full M7 balance.'
      : mint ? 'Choose an exact M7 amount. Max switches to your full USDC budget.' : 'Choose an exact M7 amount. Max uses your M7 balance.';
  $('amount-unit').disabled = state.busy || route() === 'basket';
  const balance = mint ? state.data?.usdc : state.data?.m7;
  $('max').disabled = state.busy || !state.account || state.chain !== base.id || balance == null || balance <= 0n;
  $('max').setAttribute('aria-label', `Use maximum ${mint ? 'USDC' : 'M7'} balance`);
}

async function useMax() {
  if (state.busy) return;
  clearQuote();
  setBusy(true);
  try {
    const ctx = await walletContext(), mint = state.mode === 'mint';
    const block = await client.getBlock();
    assertFresh(block);
    const balance = await client.readContract({ address: mint ? usdc : addresses.M7Vault, abi: erc20Abi, functionName: 'balanceOf', args: [ctx.account], blockNumber: block.number });
    const check = await walletContext();
    if (ctx.session !== check.session) throw new Error('Wallet changed. Select Max again.');
    if (balance <= 0n) throw new Error(`No ${mint ? 'USDC' : 'M7'} is available in this wallet.`);
    $('amount-unit').value = mint ? 'usdc' : 'm7';
    $('amount').value = exact(balance, mint ? 6 : 18);
    if (state.data) { state.data[mint ? 'usdc' : 'm7'] = balance; render(); }
  } catch (e) { report(errorText(e), null, true); }
  finally { setBusy(false); }
}

function render() {
  const d = state.data;
  const lens = d?.lens;
  $('connect').textContent = state.account ? (state.chain === base.id ? short(state.account) : 'Switch to Base') : 'Connect wallet';
  $('disconnect').hidden = !state.account;
  $('add-token').hidden = !state.account;
  $('network-note').hidden = !state.account || state.chain === base.id;
  $('price').textContent = dollars(lens?.perShare, 6);
  $('nav').textContent = dollars(lens?.nav);
  $('supply').textContent = units(d?.supply);
  $('position').textContent = state.account ? `${units(d?.m7)} M7` : 'Connect to view your balance';
  $('position-summary').hidden = !state.account;
  $('position-value').textContent = state.account && lens && d.m7 != null ? `${dollars(d.m7 * lens.perShare / 10n ** 18n)} reference value · ${short(state.account)}` : 'Your wallet signs every transaction.';
  $('balance').textContent = state.account ? `${units(d?.usdc, 6, 6)} USDC · ${units(d?.m7, 18, 6)} M7 available` : 'Connect your wallet to see balances';
  $('price-note').textContent = lens ? `Oldest price feed: ${when(lens.oldestPriceAt)}. ${Number(d.block.timestamp - lens.oldestPriceAt) > 90000 ? 'Stale reference prices. ' : ''}${lens.issuerPaused ? 'Issuer price paused. ' : ''}${lens.sequencerDown ? 'Sequencer outage reported. ' : ''}Reference values are not executable trade prices.` : !d && $('read-error').hidden ? 'Reading reference prices…' : 'Reference prices are unavailable. Direct basket redemption does not require a price feed.';
  $('assets').innerHTML = assets.map((a, i) => `<tr><td><div class="asset">${a.logo ? `<img class="asset-logo" src="${a.logo}" alt="" width="31" height="31">` : `<span class="asset-mark">$</span>`}<span><strong>${a.name}</strong><small>${a.symbol}</small></span></div></td><td title="${d?.backing[i] != null ? exact(d.backing[i], a.decimals) : ''}">${units(d?.backing[i], a.decimals, 6)}</td><td>${dollars(lens?.components[i])}</td><td>${lens?.nav ? `${(Number(lens.components[i] * 10000n / lens.nav) / 100).toFixed(2)}%` : '—'}</td></tr>`).join('');
  $('claims-card').hidden = !state.account;
  $('claims').innerHTML = !d?.claims ? '<p class="fine">Claims unavailable. Refresh to try again.</p>' : d.claims.every(v => v === 0n) ? '<p class="empty">No deferred withdrawals for this wallet.</p>' : d.claims.map((v, i) => v > 0n ? `<div class="claim-row"><span>${exact(v, assets[i].decimals)} ${assets[i].symbol}</span><button class="secondary" data-claim="${i}" ${state.busy ? 'disabled' : ''}>Review withdrawal</button></div>` : '').join('');
  renderAmount();
  renderReset();
}

function renderReset() {
  const d = state.data;
  const open = d && inWindow(d.block.timestamp);
  const enabled = !!d?.due && open;
  $('reset-badge').textContent = !d ? 'Unavailable' : d.due === false ? (d.last === d.quarter ? 'Quarter complete' : 'Cooldown') : !open ? 'Outside window' : 'Check eligibility';
  $('reset-status').textContent = !d ? 'Refresh to read the current schedule.' : d.due === false ? (d.last === d.quarter ? 'The current quarter is complete. The next quarter must also satisfy the 30-day cooldown.' : `Next tranche no earlier than ${when(d.next)}; the execution window and price checks still apply.`) : !open ? 'The next tranche is due. Waiting for the weekday execution window.' : 'The next tranche is due. Review checks current prices and simulates the reset before signing.';
  $('reset').disabled = state.busy || !enabled;
}

async function refresh() {
  if (state.loading) return;
  state.loading = true;
  const session = state.session;
  $('refresh').disabled = true;
  try {
    const data = await snapshot(state.account);
    if (session !== state.session) return;
    state.data = data;
    $('connection').textContent = `Base · Block ${data.block.number.toLocaleString()} · Updated ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    $('read-error').hidden = true;
    render();
  } catch (e) {
    if (session !== state.session) return;
    state.data = null;
    $('connection').textContent = 'Base data unavailable';
    $('read-error').textContent = errorText(e);
    $('read-error').hidden = false;
    render();
  } finally {
    state.loading = false;
    $('refresh').disabled = false;
    if (session !== state.session) void refresh();
  }
}

function discover(event) {
  const detail = event.detail;
  if (!detail?.provider?.request || !detail.info?.uuid) return;
  providers.set(detail.info.uuid, detail);
}
window.addEventListener('eip6963:announceProvider', discover);
window.dispatchEvent(new Event('eip6963:requestProvider'));

const onAccounts = accounts => changed(accounts[0] || null, state.chain);
const onChain = chain => changed(state.account, Number(chain));
const onDisconnect = () => disconnect();
function changed(account, chain) {
  state.session++;
  state.account = account && isAddress(account) ? account : null;
  state.chain = chain;
  state.data = null;
  clearQuote();
  $('review-dialog').close();
  $('claim-recipient').value = '';
  render();
  void refresh();
}
function detach() {
  state.provider?.removeListener?.('accountsChanged', onAccounts);
  state.provider?.removeListener?.('chainChanged', onChain);
  state.provider?.removeListener?.('disconnect', onDisconnect);
}
function disconnect() { detach(); state.provider = null; changed(null, null); }
async function connect(provider) {
  if (!requireRiskAcknowledgment()) return;
  try {
    const accounts = await provider.request({ method: 'eth_requestAccounts' });
    const chain = await provider.request({ method: 'eth_chainId' });
    if (!riskAccepted) return;
    detach(); state.provider = provider;
    provider.on?.('accountsChanged', onAccounts); provider.on?.('chainChanged', onChain); provider.on?.('disconnect', onDisconnect);
    changed(accounts[0], Number(chain));
    $('wallet-dialog').close();
  } catch (e) { report(errorText(e), null, true); }
}
async function switchChain() {
  try {
    await state.provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x2105' }] });
  } catch (e) {
    if (e.code !== 4902) throw e;
    await state.provider.request({ method: 'wallet_addEthereumChain', params: [{ chainId: '0x2105', chainName: 'Base', nativeCurrency: base.nativeCurrency, rpcUrls: ['https://mainnet.base.org'], blockExplorerUrls: [explorer] }] });
    await state.provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x2105' }] });
  }
  changed(state.account, Number(await state.provider.request({ method: 'eth_chainId' })));
}
function chooseWallet() {
  if (!requireRiskAcknowledgment()) return;
  if (state.account) { if (state.chain !== base.id) void switchChain().catch(e => report(errorText(e), null, true)); return; }
  const choices = [...providers.values()];
  if (!choices.length && window.ethereum?.request) choices.push({ info: { name: 'Browser wallet' }, provider: window.ethereum });
  if (choices.length === 1) { void connect(choices[0].provider); return; }
  $('wallet-list').replaceChildren();
  for (const choice of choices) {
    const button = document.createElement('button'); button.className = 'secondary full';
    button.textContent = choice.info.name; button.onclick = () => connect(choice.provider); $('wallet-list').append(button);
  }
  if (!choices.length) $('wallet-list').textContent = 'No browser wallet detected. Open this site in MetaMask’s browser or install a browser wallet, then refresh.';
  $('wallet-dialog').showModal();
}

async function walletContext() {
  if (!requireRiskAcknowledgment()) throw new Error('Review eligibility and risks before using your wallet.');
  if (!state.account || !state.provider) throw new Error('Connect your wallet first.');
  const session = state.session, account = state.account, provider = state.provider;
  const [chain, accounts] = await Promise.all([provider.request({ method: 'eth_chainId' }), provider.request({ method: 'eth_accounts' })]);
  if (session !== state.session || accounts[0]?.toLowerCase() !== account.toLowerCase()) throw new Error('The wallet account changed. Review again.');
  if (Number(chain) !== base.id) throw new Error('Switch your wallet to Base before continuing.');
  return { session, account, provider };
}

function showQuote(q) {
  $('quote-details').hidden = false;
  $('quote-details').innerHTML = q.route === 'usdc'
    ? `<dl><div><dt>${q.mode === 'mint' ? 'Receive' : 'Redeem'}</dt><dd>${exact(q.shares)} M7</dd></div><div><dt>Estimated ${q.mode === 'mint' ? 'cost' : 'proceeds'}</dt><dd>${exact(q.total, 6)} USDC</dd></div><div class="emphasis"><dt>${q.mode === 'mint' ? 'Maximum spend' : 'Minimum receive'}</dt><dd>${exact(q.limit, 6)} USDC</dd></div></dl><p class="fine">${q.mode === 'mint' ? 'You need the maximum amount available. Unspent USDC is refunded in the same transaction.' : 'The transaction reverts if proceeds fall below this minimum.'}</p>`
    : `<p class="fine">Minimum entitlements, delivered now or reserved as a claim:</p><dl>${assets.map((a, i) => `<div><dt>${a.symbol}</dt><dd>${exact(q.minimums[i], a.decimals)}</dd></div>`).join('')}</dl><p class="fine">M7 is burned. Blocked asset transfers become claims; their immediate delivery is not guaranteed.</p>`;
  $('quote-details').insertAdjacentHTML('beforeend', '<p class="fine" id="quote-clock"></p>');
  $('review').hidden = false;
  $('review').textContent = state.account ? 'Review transaction' : 'Connect wallet to continue';
  tick();
}
function tick() {
  if (!state.quote) return;
  const remaining = Math.max(0, Math.ceil((state.quote.expires - Date.now()) / 1000));
  if ($('quote-clock')) $('quote-clock').textContent = remaining ? `Quoted at block ${state.quote.block} · expires in ${remaining}s` : 'Quote expired. Preview again to refresh.';
  $('review').disabled = state.busy || remaining === 0;
  if (state.prepared?.quote) $('confirm').disabled = state.busy || remaining === 0;
}

async function preview() {
  if (state.busy) return;
  clearQuote();
  $('activity').hidden = true;
  setBusy(true);
  $('quote').textContent = route() === 'basket' ? 'Reading basket…' : 'Reading pool quotes…';
  const quoteKey = key();
  try {
    const dollars = $('amount-unit').value === 'usdc';
    const value = amount($('amount').value, dollars ? 6 : 18);
    const q = await quoteTrade({ mode: state.mode, route: route(), ...(dollars ? { usdcAmount: value } : { shares: value }), account: state.account, bps: Number($('slippage').value), key: quoteKey });
    assertQuote(q, key());
    state.quote = q;
    showQuote(q);
  } catch (e) { report(errorText(e), null, true); }
  finally { setBusy(false); $('quote').textContent = `Preview ${state.mode === 'mint' ? 'mint' : 'redemption'}`; tick(); }
}

function openReview(title, body, prepared) {
  state.prepared = prepared;
  $('review-title').textContent = title;
  $('review-body').innerHTML = body;
  $('confirm').textContent = 'Confirm in wallet';
  $('review-dialog').showModal();
}
async function prepareTrade() {
  if (!state.account) { chooseWallet(); return; }
  if (state.busy) return;
  setBusy(true);
  try {
    const ctx = await walletContext(), q = state.quote;
    assertQuote(q, key());
    const approval = approvalFor(q);
    const balanceToken = q.mode === 'mint' ? approval.token : addresses.M7Vault;
    const balance = await client.readContract({ address: balanceToken, abi: erc20Abi, functionName: 'balanceOf', args: [ctx.account] });
    if (balance < (q.mode === 'mint' ? q.limit : q.shares)) throw new Error(`Insufficient ${q.mode === 'mint' ? 'USDC for the maximum spend' : 'M7'}.`);
    const allowance = approval ? await client.readContract({ address: approval.token, abi: erc20Abi, functionName: 'allowance', args: [ctx.account, addresses.USDCGateway] }) : 0n;
    assertQuote(q, key());
    const needsApproval = approval && allowance < approval.amount;
    const request = needsApproval ? { address: approval.token, abi: erc20Abi, functionName: 'approve', args: [addresses.USDCGateway, approval.amount] } : tradeRequest(q, ctx.account, BigInt(Math.floor(Date.now() / 1000) + 600));
    await client.simulateContract({ ...request, account: ctx.account });
    assertQuote(q, key());
    openReview(needsApproval ? `Approve ${approval.symbol}` : q.mode === 'mint' ? 'Mint' : 'Redeem',
      needsApproval ? `<p>Allow the M7 gateway to spend exactly <strong>${exact(approval.amount, approval.decimals)} ${approval.symbol}</strong>.</p><p class="fine">Spender: ${link(addresses.USDCGateway)}</p><p>This is a separate transaction. After confirmation, refresh your quote and review the ${q.mode === 'mint' ? 'mint' : 'redemption'}.</p>`
        : `<dl><div><dt>${q.mode === 'mint' ? 'Receive' : 'Burn'}</dt><dd>${exact(q.shares)} M7</dd></div><div><dt>${q.route === 'basket' ? 'Receive' : q.mode === 'mint' ? 'Spend at most' : 'Receive at least'}</dt><dd>${q.route === 'basket' ? 'Basket assets or claims' : `${exact(q.limit, 6)} USDC`}</dd></div></dl>${q.route === 'basket' ? $('quote-details').innerHTML.replace(/<p class="fine" id="quote-clock">.*?<\/p>/, '') : ''}<p class="fine">Recipient: ${link(ctx.account)}<br>Contract: ${link(request.address)}</p>`,
      { ctx, quote: q, request, label: needsApproval ? `${approval.symbol} approval` : q.mode === 'mint' ? 'M7 mint' : 'M7 redemption' });
  } catch (e) { report(errorText(e), null, true); }
  finally { setBusy(false); tick(); }
}

async function prepareOther(kind, index) {
  if (!state.account) { chooseWallet(); return; }
  if (state.busy) return;
  setBusy(true);
  try {
    const ctx = await walletContext();
    let request, body, label;
    if (kind === 'reset') {
      await client.readContract(contract('Valuation', 'snapshot'));
      request = contract('IndexController', 'rebalance', [BigInt(Math.floor(Date.now() / 1000) + 600), ctx.account]);
      body = `<p>Execute one contract-defined tranche toward equal weights. This may not complete the quarter’s reset.</p><p>The contract caps the reward at 5 bp of traded value and $25. Any reward is paid to ${link(ctx.account)}.</p><p class="fine">Contract: ${link(request.address)}</p>`;
      label = 'Quarterly reset tranche';
    } else {
      const recipient = $('claim-recipient').value.trim() || ctx.account;
      if (!isAddress(recipient) || [zeroAddress, addresses.M7Vault, addresses.USDCGateway].includes(recipient.toLowerCase())) throw new Error('Enter a valid recipient address, not a protocol contract or the zero address.');
      const claims = await client.readContract(contract('M7Vault', 'claimOf', [ctx.account]));
      if (!claims[index]) throw new Error('There is no claim left for this asset.');
      request = contract('M7Vault', 'withdrawClaim', [BigInt(index), claims[index], recipient]);
      body = `<p>Withdraw <strong>${exact(claims[index], assets[index].decimals)} ${assets[index].symbol}</strong>.</p><p>Recipient: ${link(recipient, recipient)}</p><p class="fine">The issuer must permit this transfer. A failed transaction leaves the claim in place.</p>`;
      label = `${assets[index].symbol} withdrawal`;
    }
    const simulation = await client.simulateContract({ ...request, account: ctx.account });
    if (ctx.session !== state.session) throw new Error('Wallet changed. Review again.');
    // A successful simulation is only a preview; the exact request is simulated again before sending.
    void simulation;
    openReview(label, body, { ctx, request, label });
  } catch (e) { report(errorText(e), null, true); }
  finally { setBusy(false); }
}

async function send() {
  const p = state.prepared;
  if (!p || state.busy) return;
  let hash;
  setBusy(true);
  try {
    const ctx = await walletContext();
    if (ctx.session !== p.ctx.session || ctx.account !== p.ctx.account) throw new Error('Wallet changed. Review again.');
    if (p.quote) assertQuote(p.quote, key());
    const request = { ...p.request, account: ctx.account };
    await client.simulateContract(request);
    const gas = await client.estimateContractGas(request);
    const check = await walletContext();
    if (check.session !== ctx.session) throw new Error('Wallet changed. Review again.');
    if (p.quote) assertQuote(p.quote, key());
    const wallet = createWalletClient({ chain: base, transport: custom(ctx.provider), account: ctx.account });
    $('confirm').textContent = 'Waiting for wallet…';
    report(`Confirm ${p.label.toLowerCase()} in your wallet.`);
    hash = await wallet.writeContract({ ...request, chain: base, gas: gas * 3n / 2n });
    $('review-dialog').close();
    report(`${p.label} submitted. Waiting for confirmation…`, hash);
    let replaced = false;
    const receipt = await client.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 180000, onReplaced: replacement => {
      hash = replacement.transaction.hash;
      if (replacement.reason !== 'repriced') replaced = true;
      report('Waiting for the replacement transaction…', hash);
    } });
    if (replaced) throw new Error('The transaction was canceled or replaced. Check the transaction before trying again.');
    if (receipt.status !== 'success') throw new Error('The transaction reverted. No trade or approval was completed; network fees were spent.');
    report(`${p.label} confirmed.`, receipt.transactionHash);
    clearQuote();
    await refresh();
  } catch (e) {
    report(`${errorText(e)}${hash ? ' Check its status before submitting another transaction.' : ''}`, hash, true);
  } finally { setBusy(false); tick(); }
}

function setMode(mode) {
  if (mode !== state.mode) {
    $('amount').value = '';
    $('amount-unit').value = mode === 'mint' ? 'usdc' : 'm7';
  }
  state.mode = mode; clearQuote();
  if (route() === 'basket' && $('amount-unit').value !== 'm7') {
    $('amount-unit').value = 'm7';
    $('amount').value = '';
  }
  $('mint-tab').setAttribute('aria-pressed', String(mode === 'mint'));
  $('redeem-tab').setAttribute('aria-pressed', String(mode === 'redeem'));
  $('route-field').hidden = mode === 'mint';
  $('trade-title').textContent = mode === 'mint' ? 'Mint' : 'Redeem';
  $('quote').textContent = `Preview ${mode === 'mint' ? 'mint' : 'redemption'}`;
  $('trade-note').textContent = mode === 'mint' ? 'Pay USDC to receive an exact amount of M7. Pool fees are included in the quote; network fees are additional.' : route() === 'basket' ? 'Receive your proportional basket without selling through pools. Blocked transfers become deferred claims. Network fees are additional.' : 'Sell your proportional basket through the existing pools. Pool fees are included; network fees are additional.';
  renderAmount();
}
$('mint-tab').onclick = () => setMode('mint');
$('redeem-tab').onclick = () => setMode('redeem');
$('route').onchange = () => setMode(state.mode);
$('amount').oninput = clearQuote;
$('amount-unit').onchange = () => { $('amount').value = ''; clearQuote(); renderAmount(); $('amount').focus(); };
$('max').onclick = useMax;
$('slippage').onchange = clearQuote;
$('quote').onclick = preview;
$('review').onclick = prepareTrade;
$('confirm').onclick = send;
$('connect').onclick = chooseWallet;
$('disconnect').onclick = disconnect;
$('refresh').onclick = refresh;
$('reset').onclick = () => prepareOther('reset');
$('claims').onclick = e => { const button = e.target.closest('[data-claim]'); if (button) void prepareOther('claim', Number(button.dataset.claim)); };
$('add-token').onclick = async () => {
  try {
    const ctx = await walletContext();
    const added = await ctx.provider.request({ method: 'wallet_watchAsset', params: { type: 'ERC20', options: {
      address: addresses.M7Vault, symbol: 'M7', decimals: 18,
      image: new URL('token-icon.png', document.baseURI).href,
    } } });
    report(added ? 'M7 added to your wallet.' : 'Adding M7 was canceled.');
  } catch (e) { report(errorText(e), null, true); }
};
document.querySelectorAll('[data-close]').forEach(button => button.onclick = () => $(button.dataset.close).close());
$('review-dialog').addEventListener('cancel', e => { if (state.busy) e.preventDefault(); });
render();
if (!riskAccepted) showRiskNotice();
void refresh();
setInterval(() => { if (!document.hidden && !state.busy) void refresh(); }, 30000);
setInterval(tick, 1000);
