# Base integration evidence and launch gates

`config/base.json` pins canonical assets and integrations with primary-source URLs. Its `verification` field records a read-only onchain snapshot at Base block **51,830,549**, hash `0xf823c24396bac6cfacb24c8d46a6e3c3555e121bbdfa9b88af2beaa2fcb1f23b`, timestamp **2026-09-26 19:20:45 UTC**. It is historical evidence, not deployment approval. No wallet was used and no live transaction was signed, funded, or broadcast. A subsequent local Base fork executed the full stock acquisition, bootstrap, and gateway round trip, as recorded below.

## Verified integrations

All seven [Coinbase-issued stock records](https://api.coinbase.com/v1/tokenized-stocks) matched the [official Base list](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks), with 8 token decimals and 8 feed decimals. Onchain calls confirmed positive token supply, unpaused transfers, live issuer multipliers, and unpaused issuer reference feeds. Token names/symbols are mutable; contract integrations use addresses.

The stocks are B20 native precompiles and have no ordinary bytecode. Never reject them with `address.code.length == 0`. Standard ERC-20 calls, exact balance-delta checks, and Base-aware execution are required. Ordinary Anvil forks may not implement the B20 precompile. The native integration tests use Base's Foundry build, base-anvil; the ordinary mocked unit suite alone does not establish native compatibility. [B20 integration notes](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks)

All seven direct USDC pairs exist with active liquidity at tick spacing **10** on Aerodrome's gauges V3 factory. The router and quoter both report that same factory. Initial and gauge-caps factories were also probed across tick spacings 1, 10, 50, 100, 200, 500, and 2000; no stock pairs were found there. Chosen deployments come from the [Aerodrome repository](https://github.com/aerodrome-finance/slipstream#deployments).

Anyone can create a pool at an unused enabled tick spacing on this factory, and non-canonical constituent pools already exist. On 2026-09-26, AAPLc/USDC at tick spacing 200 had zero active liquidity at the minimum tick, and AMZNc/USDC at 1 and NVDAc/USDC at 200 held only dust. The vault therefore pins each stock's reviewed tick spacing (`tick_spacing` in the manifest, currently 10) at construction. Neither rebalances nor the gateway can use any other pool.

| Integration | Address |
| --- | --- |
| Slipstream factory | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` |
| Swap router | `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F` |
| Quoter | `0x514c8B5f54112481E28028F1166Bd78501089259` |
| Coinbase oracle registry | `0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD` |
| B20 policy registry | `0x8453000000000000000000000000000000000002` |
| UMA OOv3 | `0x2aBf1Bd76655de80eDB3086114315Eec75AF500c` |

The issuer oracle registry's verified ABI has `getOracleParams(address) -> (uint256 multiplier, bool paused)`. The actual onchain read succeeded for all seven tokens. Transfer sender, receiver, and executor policy IDs were all 5 at the observation block, and the selected pools, router, and quoter were authorized for those policies. Future vault/gateway/holder addresses must be checked individually: a public pool's authorization does not establish theirs. Policies may change. Policy 5 authorized an arbitrary address when probed, so it behaves as a blocklist. The three transfer-scope constants equal the Keccak-256 of their names on every stock; the preflight checks this and the vault requires it. M7CAP applies the same sender, receiver and executor policies to its own holders through the registry at `0x8453…0002`. An address blocked for any stock therefore cannot receive, send or redeem M7CAP. A switch to an allowlist would also freeze M7CAP held by unlisted contracts. [Verified registry source](https://base.blockscout.com/api/v2/smart-contracts/0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD), [B20 interfaces](https://github.com/base/base-std/blob/main/src/interfaces/IB20.sol)

Native USDC has 6 decimals and its USD feed has 8 decimals. The Base sequencer reported up beyond the grace period. UMA's `getMinimumBond(USDC)` returned **500,000,000 raw USDC = 500 USDC**; this is separate bond capital, not stock backing or necessarily a spent fee. Re-query at proposal time. [Circle addresses](https://developers.circle.com/stablecoins/usdc-contract-addresses), [UMA addresses](https://github.com/UMAprotocol/protocol/blob/master/packages/core/networks/8453.json)

## UMA identifier and collateral readiness

A mainnet-fork test exposed an integration trap: the deployed OOv3's `defaultIdentifier()` remains `ASSERT_TRUTH`, although the current IdentifierWhitelist rejects it. Calling `getMinimumBond()` successfully does not establish that an assertion can be made. M7CAP explicitly pins **`ASSERT_TRUTH2`**, with no fallback to the contract default. This replacement is listed in UMA's [approved identifiers](https://docs.uma.xyz/resources/approved-price-identifiers) and [UMIP-191](https://github.com/UMAprotocol/UMIPs/blob/master/UMIPs/umip-191.md).

At block **51,830,957**, the preflight dynamically resolved Finder's IdentifierWhitelist, CollateralWhitelist, Store, Oracle, and OptimisticOracleV3 implementations. It confirmed the selected OOv3 matched Finder, `ASSERT_TRUTH2` was approved, USDC was approved, and the deprecated default was unsupported. The new identifier's bytes32 encoding is `0x4153534552545f54525554483200000000000000000000000000000000000000` (right padding, not numeric left padding). Current Store final fee was 250 USDC and burned-bond fraction was 50%, making the post-sync minimum bond 500 USDC.

`verify_base.py` also records cached identifier/currency/fee values and simulates `syncUmaParams` with `eth_call`; no cache change is persisted onchain. It fails if the explicit identifier or collateral has been removed from the current allowlist, even when an old cache and positive bond value remain. `config/base.json` → `uma_readiness_verification` stores this separate observation. A false support flag for the old default is expected; the pinned identifier's support must be true.

## Executable quote probes

The quoter successfully simulated exact-output USDC purchases and exact-input stock sales for all seven pairs, for $10, $100, and $1,000 reference-value baskets at the fixed block. **These probes use equal dollar allocations only to exercise liquidity; they are not M7CAP market-cap weights.** Actual quarter-end company-share observations were not supplied and have not been invented.

| Reference USD basket value | USDC to buy exact stock quantities | USDC received selling those quantities |
| ---: | ---: | ---: |
| 10 | 9.993912 | 9.983896 |
| 100 | 99.939214 | 99.839267 |
| 1,000 | 999.392388 | 998.392821 |

Buy and sell quotes are independent calls against the same starting block, not consecutive legs of a simulated round trip. Values exclude gas and are relative to the published oracle reference (which can be stale), not an assertion of current fair value. Per-component raw quantities and quote results are in the manifest. An `eth_call` quoter result does not prove that a funded user can complete a seven-swap atomic gateway transaction, including all issuer policy checks.

Both stock and USDC feeds have published 24-hour heartbeats. Stock reference values also stop updating outside market sessions. The controller's execution policy requires:
- every stock update at most **25 hours** old (heartbeat liveness);
- at least one stock update at most **1 hour** old, as evidence the market is trading;
- USDC at most **25 hours** old;
- a **1-hour** sequencer recovery grace period;
- weekdays **15:00–20:00 UTC**.

A quiet feed inside its 0.5% deviation band is still accurate, so it no longer blocks execution. Holidays fail closed unless a heartbeat lands on them. The planner's per-leg oracle minimums and bounded step limit what a stale-but-accepted price can cost. Quantity-based basket mint/redeem does not use these reference prices. At the captured weekend block the window is closed, and the read preflight correctly reports rebalance ineligible.

`scripts/feed_availability.py` replays past windows from each feed's round history. For the ten weekdays from 2026-09-14 to 2026-09-25 (Base block 51,835,998), in ten-minute slots:

| Rule | Usable slots | Weekdays with no usable slot |
| --- | ---: | ---: |
| Original: every stock ≤1 h, 15:00–17:00 UTC | 1 of 120 | 9 of 10 |
| Current: every stock ≤25 h and one ≤1 h, 15:00–20:00 UTC | 288 of 300 | 0 of 10 |

Registry pauses and sequencer outages are not replayed. [Feed behavior](https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase), [USDC feed directory](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json), [sequencer guidance](https://docs.chain.link/data-feeds/l2-sequencer-feeds)

## Native Base fork tests

`test/BaseFork.t.sol` runs the current contracts against live Base state with native B20 execution. On 2026-09-27 all five tests passed with base-anvil `nightly-98e7839c65f6` (base/base `3eb4817`, binaries checked with `gh attestation verify`), under both precompile rule sets: Beryl, which mainnet runs until 2026-09-30 18:00 UTC, and Cobalt after that. Figures below are from the Cobalt run at block **51,869,461**. Each test creates USDC only in local fork storage and acquires every B20 through its actual Slipstream pool. No B20 balance or code is fabricated, and nothing is broadcast.

- **Round trip** (`testBaseNativeB20BootstrapAndUSDCRoundTrip`). A seed of 100 USDC per stock, an equal-dollar fixture, bootstrapped the vault. The fee-free gateway minted 100 M7CAP for **70.000037 USDC** and redeemed them for **69.929990 USDC**; the difference is pool pricing. Assertions cover shares, refunds, the vault's backing, the gateway holding nothing afterwards, and cleared allowances.
- **UMA** (`testBaseLiveUMAAssertionAndBondRefund`). The deployed OOv3 with `ASSERT_TRUTH2`: a 500 USDC minimum and 1,000 USDC supplied bond, the 72-hour window, early settlement refused, permissionless acceptance after time travel, and a full bond refund. There are no oracle mocks or whitelist changes, and the claim is a labelled fixture.
- **Rebalance** (`testBaseNativeRebalanceAgainstLivePools`). A real UMA acceptance of ratios one step from the seed, then `execute` through the live pinned pools. Feeds are mocked only to report their fork-time answers as fresh after the time travel. It made two legs of about $4.50 each, used 563k gas, lost nothing in NAV, and met the 30 bp compliance and cash bounds.
- **Price per share** (`testBaseNativeLensPricesShares`). `M7CapLens` values a seed bought for 700 USDC at **$0.6997** per share from the live feeds, while its stalest price was 49 hours old over the weekend.
- **Policies and exits** (`testBaseNativeTransferGasAndResilientRedemption`). M7CAP transfers against the real policy registry cost about 52k gas to a new holder and 28k to an existing one. These are measured inside one test transaction; a standalone transfer also pays cold account access. `redeemBasketWithClaims` delivered every leg, with no claims.

`script/rehearse.sh` also ran the mainnet runbook end to end on a local base-anvil fork under both rule sets:
- deploy, and 65 deployment checks with bytecode matching the build;
- the seed bought for 999.84 USDC against a $1,000 oracle value;
- bootstrap, and 85 post-bootstrap checks;
- gateway and in-kind smoke tests;
- a fixture proposal, 72 hours of time travel, settlement, and the monitor.

Before the remediation, the round trip and UMA tests had passed at block 51,830,602 with base-anvil v1.1.0. The machine-readable record is `config/base.json` → `native_fork_verification`. The tests are opt-in (`BASE_FORK_TEST=true`, `FOUNDRY_BASE=beryl|cobalt`) and need the Base-specific `forge`; the ordinary suite skips them. Still unvalidated: the disputed cross-chain UMA path, production observations and addresses, and anything with live funds.

## Reproduce and complete acceptance

With Python 3.9+ and Foundry `cast` installed:

```sh
python3 scripts/verify_base.py
python3 scripts/verify_base.py --rpc "$BASE_RPC_URL" --snapshot snapshot.json --account 0xYOUR_VAULT --account 0xYOUR_GATEWAY
python3 -m unittest discover -s test -p 'test_*.py'
```

The second command requires real addresses and the output of `index_snapshot.py`; the placeholder strings intentionally cannot be submitted. `--snapshot` uses that snapshot's human quantity ratios valued at the current feed snapshot to apportion the liquidity probes. It does not validate company capitalization evidence. Every onchain read is pinned to one block. The script requires Base chain ID 8453, validates identities/decimals, reads issuer pauses/policies, checks pool identity/liquidity and router factories, verifies the explicit UMA identifier/collateral through current Finder allowlists and post-sync bond requirements, and obtains both quote directions. Unknown, invalid, or failed reads exit nonzero; stale prices also exit nonzero. JSON always includes `launch_ready: false`, because no collection of these read checks establishes full production readiness. Default RPC is `https://base-rpc.publicnode.com`; a configured authenticated provider is preferable for repeated monitoring.

Before seeding, complete the gates in [the deployment runbook](DEPLOYMENT.md):

1. Produce and independently review sourced quarter-end observations and the bootstrap basket; exercise the actual market-cap allocation with `--snapshot`.
2. Re-run the native tests and `script/rehearse.sh` on a post-Cobalt block, then verify the deployment with `scripts/verify_deployment.py` before funding it.
3. Establish the permitted wrapper distribution and issuer eligibility, and publish the immutable methodology and evidence. The owner has decided to launch without an independent security review.
4. Fund and operate UMA proposal and dispute monitoring (`scripts/monitor.py`); test alerting before the first assertion. Public CLI reads alone are not a continuously running monitor.
5. Re-run current source verification and read checks immediately before any deployment or bootstrap. Passing historical quotes does not reserve liquidity.

No dedicated M7CAP/USDC liquidity pool is required. The ~$1,000 is seed backing; fees paid to existing pools, deployment gas, audits, monitoring, and oracle bonds are additional costs. The precision reserve permanently locks 10 of the initial 1,000 M7CAP shares (about $10 of a $1,000 seed). The reviewed bootstrap must hold at least 0.01 of every stock token to satisfy the minimum projected reserve of 10,000 raw units per stock. See the [first](AUDIT.md) and [second](AUDIT-2.md) internal reviews for the findings, fixes and residual risks.
