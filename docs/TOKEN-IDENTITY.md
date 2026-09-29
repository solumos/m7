# M7 logo and wallet classification

Prepared September 28, 2026. The user reports a token-level "suspicious" label in
MetaMask; its exact text and the reason for the classification have not yet been
captured. No review request or token-information submission has been sent.

## Identity and logo assets

- Network: Base mainnet, chain ID 8453.
- Token: M7 Equal Weight; symbol M7; decimals 18.
- Contract: `0x1aD2e897e19e659C0AEcdB19C1C714F861865BeE`.
- [BaseScan contract](https://basescan.org/address/0x1ad2e897e19e659c0aecdb19c1c714f861865bee#code).
- [BaseScan token tracker](https://basescan.org/token/0x1ad2e897e19e659c0aecdb19c1c714f861865bee).
- [Sourcify source](https://repo.sourcify.dev/8453/0x1ad2e897e19e659c0aecdb19c1c714f861865bee).
- [32 × 32 SVG](../ui/public/token-icon.svg), [64 × 64 PNG](../ui/public/token-icon.png).
- Website: <https://m7token.xyz>.
- Public logo: [SVG](https://m7token.xyz/token-icon.svg), [PNG](https://m7token.xyz/token-icon.png).

The domain is registered and hosted on Vercel. Public DNS, valid HTTPS, and the
`www` redirect were verified on September 28, 2026.

The logo uses the site's existing original neon M7 mark and is covered by the
root Unlicense. The SVG contains only local vector paths; it has no scripts,
fonts, remote resources or issuer branding. The PNG is rendered from that mark.

The website's **Add M7** button supplies the PNG URL through
[`wallet_watchAsset`](https://docs.metamask.io/metamask-connect/evm/guides/metamask-exclusive/display-tokens/).
That is a wallet import request, not a global listing or a security endorsement.
The public PNG URL is `https://m7token.xyz/token-icon.png`.

## Explorer listing

[BaseScan's guidelines](https://info.basescan.org/how-to-update-token-info/)
require published verified source, creator-address verification, an accessible
website and logo, and project contact details. The supplied logo assets match
its recommended dimensions. Submit one token-information request through the
official form after those details are ready; the standard update is free and
subject to their review. An explorer update does not imply MetaMask will use the
same logo or remove a warning.

BaseScan calls the creator proof
["Verify Contract Address Ownership"](https://info.basescan.org/verifyaddress/).
It links the deployer's signed message to an explorer account for editing the
offchain listing. It does not add an onchain owner, administrator or upgrade key
to M7.

Suggested neutral description:

> M7 is an ERC-20 basket receipt on Base designed to track an equal-weight basket
> of tokenized Apple, Amazon, Alphabet, Meta, Microsoft, NVIDIA and Tesla stocks.
> Each stock has a target weight of one-seventh. Holders can mint and redeem
> through the deployed contracts. Quarterly resets are permissionless and subject
> to execution checks. Actual weights and returns can differ from the target.

The public website URL is `https://m7token.xyz`; a project contact email remains
to be supplied. Do not submit localhost or private repository URLs as publicly
accessible project links.

## MetaMask review

Per [MetaMask's security-alert guidance](https://support.metamask.io/configure/wallet/security-alerts/),
token/address/URL classifications should be raised with official support. The
in-alert **Report an issue** flow currently applies to transaction alerts. A
review may revise a classification; there is no guaranteed removal or verified
badge. A logo, source verification and an absence of warnings are not proof of
safety. MetaMask's legacy metadata repository is
[effectively frozen](https://github.com/MetaMask/contract-metadata); its stated
recommendation for new tokens is the wallet import method above.

Review-request draft (not submitted):

> Please review the token-level suspicious classification for M7 Equal Weight
> (M7) on Base mainnet, chain ID 8453, at
> 0x1aD2e897e19e659C0AEcdB19C1C714F861865BeE.
>
> M7 is an ERC-20 receipt for a basket of seven tokenized stocks. It has no owner,
> upgrade authority or discretionary minting role. Holders mint against basket
> deposits and redeem their proportional backing. The immutable USDC gateway at
> 0xAbA592b5fdC0e3c48a9C1f1F7A3a9aebA17BCf1C buys or sells the constituents through
> pinned Aerodrome Slipstream pools. The underlying Base-native stock tokens
> enforce issuer transfer policies, and failed delivery during a resilient
> basket redemption can create a deferred claim for the redeemer.
>
> Public contract and source references:
> https://basescan.org/address/0x1ad2e897e19e659c0aecdb19c1c714f861865bee#code
> https://repo.sourcify.dev/8453/0x1ad2e897e19e659c0aecdb19c1c714f861865bee
>
> The software has not received an independent security audit. We are asking for
> an assessment of the classification and an explanation of any triggered risk
> indicators, not a safety guarantee or investment endorsement.

Before sending, attach the exact warning text/screenshot, MetaMask version and
device type; include `https://m7token.xyz`. Confirm that the warning
is for the exact contract above. No private key, seed phrase or transaction
approval is required to supply this evidence.
