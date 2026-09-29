# M7 website

A static, wallet-connected interface for the deployed M7 contracts on Base (8453).
No backend, administrator, API key, custodial wallet, analytics, or signing secret.

Primary domain: <https://m7token.xyz> ([live Vercel URL](https://m7-basket.vercel.app)).
`www.m7token.xyz` redirects to the primary domain. Public DNS, valid HTTPS, and
the redirect were verified on September 28, 2026.

```sh
cd ui
npm ci
npm run dev
```

Open the printed local URL in a browser with MetaMask or another injected wallet.
On mobile, open a hosted copy in the wallet's built-in browser. EIP-6963 wallet
discovery and the legacy injected-provider fallback are supported; WalletConnect
and exchange trading are not included.

The **Add M7** button requests a wallet import with the contract address, symbol,
decimals and the site's `token-icon.png`. This supplies a logo for that import;
it does not register M7 globally or change a wallet's security classification.
The icon needs a publicly reachable URL for public use. See
[token identity and review steps](../docs/TOKEN-IDENTITY.md) for the prepared logo
assets, BaseScan listing requirements and MetaMask classification-review draft.

## Mint and redeem

On the first visit in each tab session, a dialog explains US unavailability,
unaudited-contract and total-loss risks, no warranties, and no investment advice.
Two unchecked boxes require location eligibility and risk acknowledgment before
wallet access. **View site only** or Escape leaves public reads and quotes
available; wallet actions reopen the dialog. **Eligibility & risks** in the
footer reopens it, and choosing view-only there clears the acknowledgment and
disconnects the interface. A versioned `sessionStorage` flag survives reloads;
if storage is blocked, acknowledgment lasts only for the current page.

This is a frontend disclosure and self-attestation, not IP geoblocking,
identity verification, or an onchain restriction. It does not establish legal
compliance or modify the Unlicense. Legal enforceability and any additional
eligibility requirements need qualified legal review.

1. Acknowledge eligibility and risks, then connect your wallet and switch to Base.
   Hold ETH on Base for network fees.
2. Choose **Mint** or **Redeem**. Enter USDC or M7 using the currency selector,
   or select **Max** to use your available balance.
3. Preview the quote and review the maximum USDC spend or minimum USDC receipt.
4. If approval is required, approve the exact amount in your wallet. After it
   confirms, preview again and review/sign the actual mint or redemption.

M7 entry specifies an exact quantity. USDC entry sets a mint budget (including
slippage) or a minimum redemption receipt. The preview sizes M7 using actual pool
quotes at one block, never the dashboard reference value. Review the resulting
M7 quantity and signed USDC limit before continuing. Max reads a fresh wallet
balance: USDC for minting, M7 for redemption, and switches the input accordingly.
ETH for gas is separate. A mint pulls the maximum USDC amount and refunds unused
USDC atomically. Redemption to USDC
sells the basket through its existing Slipstream pools; no M7/USDC pool is needed.

Choose **Underlying basket** and enter M7 to redeem directly without an oracle or exchange
quote. Each displayed minimum is an entitlement, delivered or deferred. Assets
that cannot transfer become claims owned by the redeeming wallet. Claims can be
withdrawn to another eligible recipient, subject to issuer restrictions.

The protocol section also lets anyone review and run an eligible reset tranche.
It simulates current eligibility before asking for a signature. The contract's
execution window and price/turnover checks remain authoritative.

## Pricing and transaction limits

- Dashboard reference value comes from `M7Lens.value()`, including the oldest
  feed timestamp and pause/outage warnings. It is not a trade price.
- Trade previews read proportional vault quantities, then simulate Aerodrome's
  exact-output buys or exact-input sells at a single block. Quotes include pool
  fees and price impact; they exclude network fees.
- Amounts and slippage bounds use integer arithmetic. Quotes expire 60 seconds
  after the quoted block; stale RPC blocks are rejected. Transaction deadlines
  are ten minutes. Signed slippage bounds still apply if wallet confirmation
  takes longer than the preview's lifetime.
- Approval and trade are separate, user-confirmed transactions. Every send is
  simulated and gas-estimated, uses fixed deployment addresses, and rechecks the
  wallet account/network. Changing either clears pending reviews.
- Receipts must report success. Canceled/replaced transactions and reverted
  receipts are not reported as completed trades. A timed-out transaction can
  still confirm: inspect its linked explorer page before resubmitting.

`src/abi.js` contains readable signatures for only the functions and errors the
site uses. The ABI test detects drift when Foundry artifacts are available.
Deployment addresses and stock routes come from the repository's deployment and
Base configuration records. No contract code changes are needed for this site.

## Build, check, and host

Requires Node 22.12+ (or another version supported by Vite 8).

```sh
npm test
npm run test:browser
npm run build
npm run preview
```

Browser checks use local Google Chrome (`channel: 'chrome'`) and mocked RPC/wallet
responses. They never spend funds. Install Chrome before running them, or change
the Playwright channel to an installed supported browser. These checks cover
mint/approval separation, redemption limits, wallet/chain changes, expiry,
rejection/reverted receipts, direct basket exits without prices, and claims.

Upload the contents of `dist/` to any static HTTPS host. Relative asset paths also
support a subdirectory or IPFS gateway; no rewrite rules or server code are needed.
The build embeds no secret. Use a stable HTTPS origin for public wallet access.

Vercel is configured from the repository root in `vercel.json`, so the build can
include the root license. To deploy the locally verified production build:

```sh
# Run from the repository root, after linking to your Vercel project.
vercel pull --yes --environment=production
vercel build --prod
vercel deploy --prebuilt --prod
```

The Vercel build installs the pinned UI dependencies and produces static files;
no runtime environment variables or server functions are needed.

Social previews use static Open Graph and X/Twitter tags in `index.html`, so
crawlers do not need JavaScript. `public/social-card-v1.png` is the 1200×630
share image; `social-card.svg` is its editable source and uses the bundled
Chakra Petch Semibold font. Export with that font installed or outlined.
The PNG is committed, so deployment needs no image-generation dependencies.
When replacing it, version the filename and update both image URLs in the HTML
to avoid reusing a cached image. `public/robots.txt` allows crawler access.

The default read transports are PublicNode and Base's public RPC. They may be
rate-limited or unavailable; failures are shown in the UI. For higher traffic,
change the public read endpoints in `src/chain.js`. Never put a private API secret
in the frontend. Wallets handle signing and transaction submission themselves.

The build includes the root Unlicense and the full MIT notices for runtime
dependencies. Original M7 software is supplied without warranty. Issuer, pool,
oracle and Base dependencies remain; the UI does not remove contract risk.
