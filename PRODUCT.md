# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Everyday wallet users who want to understand, mint, hold, and redeem M7. Explain
each step without assuming familiarity with DeFi terminology, token approvals,
slippage, or the difference between a reference value and an executable quote.

## Product Purpose

M7 is a transferable token on Base designed to track an equal-weight basket of
the seven underlying Magnificent Seven stocks through tokenized assets: Apple,
Amazon, Alphabet, Meta, Microsoft, NVIDIA, and Tesla. The website makes minting
and redemption understandable and usable directly from the user's wallet.

Success means users can understand the basket, review transaction amounts and
limits, sign the intended transaction, and see an accurate outcome.

## Positioning

M7 shares represent proportional ownership of the vault's actual token basket,
including incidental USDC. The contracts target one-seventh of stock value per
constituent through permissionless quarterly resets. Weights can drift between
resets; equal weight is a target, and exact tracking is not guaranteed.

Full decentralization is the project's goal. M7 has no contract administrator,
owner privileges, or upgrade keys. Stock issuers, transfer policies, price feeds,
liquidity pools, and Base remain external dependencies; do not describe the
system as immune to those dependencies or to transaction ordering risks.

## Operating Context

The existing website lives in `ui/` and uses Vite, vanilla JavaScript/CSS, and
viem. It builds into a static site with no backend or signing secrets. Users
connect an injected wallet such as MetaMask on Base mainnet (chain ID 8453).
Mobile users currently need a wallet's built-in browser. ETH on Base pays gas.

The primary flow is acknowledge eligibility and risks, connect a wallet, choose mint or redeem, enter USDC or M7,
preview, approve if needed, preview again, and sign the trade. Approval
and trading are separate transactions. The wallet remains responsible for keys
and signing. Users can inspect deployed contract addresses and transaction links.

## Capabilities and Constraints

- Mint an exact amount of M7 using USDC; redeem M7 to USDC or the underlying
  basket. The USDC route uses existing constituent pools and needs no separate
  M7 exchange pool.
- USDC entry sets a mint budget or minimum redemption receipt; pool quotes size
  the exact M7 quantity. Max uses the wallet's USDC balance for minting and M7
  balance for redemption. Underlying basket redemption uses M7 entry.
- Display holdings, actual basket weights, supply, and oracle reference values.
  Distinguish those estimates from size-dependent pool quotes and signed limits.
- Preserve quote expiry, slippage bounds, transaction simulation, explicit
  wallet confirmation, and receipt verification. Explain failures accurately.
- Basket redemption can create deferred claims for assets that cannot transfer.
  Claim withdrawal remains subject to issuer restrictions and reserve risks.
- Anyone can execute an eligible reset tranche; contract rules determine trades
  and eligibility. Do not introduce an administrator to simplify the interface.
- Original software uses the Unlicense and is supplied without warranty or
  guarantee. Preserve third-party licenses and notices. Independent audit and
  wallet approval claims require evidence; the contracts have no independent audit.

## Brand Commitments

Use the name M7 and include “Magnificent Seven.” Clearly describe the equal-weight
basket of seven underlying stocks. Use restrained cyberpunk styling, the actual
company logos, simple layouts, and minimal decoration. Explain transactions in
plain, direct language. Highlight “No
management fee” using that terminology, not “holding fee.” Compare against Reserve
MAG7 and Roundhill MAGS using dated primary sources. Keep management fees, total
expenses, transaction costs, and basket reset rewards distinct.

Company logos and the M7 token icon are existing assets. Company marks do not
imply endorsement or affiliation, and the Unlicense does not relicense them.

## Evidence on Hand

- `docs/METHODOLOGY.md` and `docs/ARCHITECTURE-REVIEW.md`: contract rules and
  dependency limitations.
- `deployments/base-mainnet.json`, `deployments/base-mainnet-launch.json`, and
  `deployments/base-mainnet-source.json`: deployment, bootstrap, and verification.
- `ui/README.md`: implemented wallet flows, pricing, checks, and hosting details.
- `ui/public/companies/sources.json`: company-logo provenance.
- `ui/public/favicon.svg` and `ui/public/token-icon.png`: M7 identity assets.
- `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `docs/TOKEN-IDENTITY.md`: licensing and
  prepared token-identity material. Review drafts are not proof of submission.

## Product Principles

1. Make every wallet action and its result understandable to everyday users.
2. Preserve user custody and the absence of protocol administrator privileges.
3. Ground prices, balances, transaction outcomes, and public claims in evidence.
4. Keep exits and deferred claims understandable when dependencies fail.
5. Keep the website simple to build, verify, and host as free software.

## Open Decisions

The public site is https://m7token.xyz, hosted on Vercel.
No wallet reputation review outcome or company endorsement has been established.
