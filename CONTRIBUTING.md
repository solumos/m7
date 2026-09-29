# Contributing to M7

M7 includes the contracts, website, tests, and operational tools in one repository.
Start with the [README](README.md), [methodology](docs/METHODOLOGY.md), and
[architecture review](docs/ARCHITECTURE-REVIEW.md). Website details are in
[ui/README.md](ui/README.md); interface principles are in [PRODUCT.md](PRODUCT.md).

## Development

Install the pinned dependencies with `make deps` and `npm --prefix ui ci`.
Run `make check` for contract and Python changes, and `make ui-check` for website
changes. Wallet-flow changes also need the mocked browser checks documented in
the website README. Live integration tests require an explicit opt-in and a
Base-compatible Foundry build; ordinary tests do not broadcast transactions.

Operational commands share `scripts/`: use `forge script scripts/Name.s.sol:Name`
for Solidity and `python3 -m scripts.name` for Python, from the repository root.
Python tools use only the standard library plus Foundry's `cast`; shared RPC and
encoding helpers belong in `scripts/common.py`.

Keep changes focused. Include a regression test for changes to accounting,
execution limits, wallet behavior, or other nontrivial logic. Explain the
resulting behavior, validation, and relevant limitations in the pull request.

The deployed contracts are immutable. A source change does not update them;
changing protocol behavior requires a separate deployment and, where applicable,
voluntary migration. The website and read-only tooling can evolve independently.

## Files and release evidence

Commit source, lockfiles, public assets, and relevant documentation. Preserve
public deployment addresses, transaction hashes, source commits, and dated
validation evidence. Historical records describe their recorded block, not
current onchain state. Mark internal reviews as internal; do not describe them
as independent audits.

Keep `.env` files, keystores, private RPC credentials, webhooks, build output,
installed dependencies, and local tool state out of Git. Use the committed
example files for operator configuration. Never include wallet keys or recovery
phrases in code, issues, pull requests, or logs.

## Licensing

Submit original contributions under the [Unlicense](LICENSE). Identify any
third-party code or assets, preserve their notices, and update
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) when needed. Company logos and
trademarks are not covered by M7's public-domain dedication.
