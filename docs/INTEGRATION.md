# Base integration evidence and launch gates

`config/base.json` pins canonical assets and integrations with primary-source URLs. Its `verification` field records a read-only onchain snapshot at Base block **51,894,325**, hash `0x040478d56ecc33ed757c8b8a93d41592454b0c5ba1d1962a14bea48538cb3371`, timestamp **2026-09-28 06:46:37 UTC**. It is historical evidence, not deployment approval. No wallet was used and no live transaction was signed, funded, or broadcast. Subsequent local Base forks executed the full stock acquisition, bootstrap, gateway round trip and an equal-weight reset, as recorded below.

## Verified integrations

All seven [Coinbase-issued stock records](https://api.coinbase.com/v1/tokenized-stocks) matched the [official Base list](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks), with 8 token decimals and 8 feed decimals. Onchain calls confirmed positive token supply, unpaused transfers, live issuer multipliers, and unpaused issuer reference feeds. Token names/symbols are mutable; contract integrations use addresses.

The stocks are B20 native precompiles and have no ordinary bytecode. Never reject them with `address.code.length == 0`. Standard ERC-20 calls, exact balance-delta checks, and Base-aware execution are required. Ordinary Anvil forks may not implement the B20 precompile. The native integration tests use Base's Foundry build, base-anvil; the ordinary mocked unit suite alone does not establish native compatibility. [B20 integration notes](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks)

All seven direct USDC pairs exist with active liquidity at tick spacing **10** on Aerodrome's gauges V3 factory. The router and quoter both report that same factory. Initial and gauge-caps factories were also probed across tick spacings 1, 10, 50, 100, 200, 500, and 2000; no stock pairs were found there. Chosen deployments come from the [Aerodrome repository](https://github.com/aerodrome-finance/slipstream#deployments).

Anyone can create a pool at an unused enabled tick spacing on this factory, and non-canonical constituent pools already exist. On 2026-09-26, AAPLc/USDC at tick spacing 200 had zero active liquidity at the minimum tick, and AMZNc/USDC at 1 and NVDAc/USDC at 200 held only dust. The vault therefore pins each stock's reviewed tick spacing (`tick_spacing` in the manifest, currently 10) at construction. Neither resets nor the gateway can use any other pool. Before a reset trades in a pool, it compares the pool's price with its own 10-minute average, which needs 300 stored price observations at one per block: the pinned pools keep 360 (AMZNc, MSFTc, TSLAc) or 2,048 (the others), and the preflight checks this.

| Integration | Address |
| --- | --- |
| Slipstream factory | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` |
| Swap router | `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F` |
| Quoter | `0x514c8B5f54112481E28028F1166Bd78501089259` |
| Coinbase oracle registry | `0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD` |
| B20 policy registry | `0x8453000000000000000000000000000000000002` |

The issuer oracle registry's verified ABI has `getOracleParams(address) -> (uint256 multiplier, bool paused)`. The actual onchain read succeeded for all seven tokens. Transfer sender, receiver, and executor policy IDs were all 5 at the observation block, and the selected pools, router, and quoter were authorized for those policies. Future vault/gateway/holder addresses must be checked individually: a public pool's authorization does not establish theirs. Policies may change. Policy 5 authorized an arbitrary address when probed, so it behaves as a blocklist. The three transfer-scope constants equal the Keccak-256 of their names on every stock; the preflight checks this and the vault requires it. M7 applies the same sender, receiver and executor policies to its own holders through the registry at `0x8453…0002`. An address blocked for any stock therefore cannot receive, send or redeem M7. A switch to an allowlist would also freeze M7 held by unlisted contracts. [Verified registry source](https://base.blockscout.com/api/v2/smart-contracts/0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD), [B20 interfaces](https://github.com/base/base-std/blob/main/src/interfaces/IB20.sol)

Native USDC has 6 decimals and its USD feed has 8 decimals. The Base sequencer reported up beyond the grace period. [Circle addresses](https://developers.circle.com/stablecoins/usdc-contract-addresses)

## Executable quote probes

The quoter successfully simulated exact-output USDC purchases and exact-input stock sales for all seven pairs, for $10, $100, and $1,000 reference-value baskets at the fixed block. The probes use equal dollar allocations, which are M7's own weights at each reset.

| Reference USD basket value | USDC to buy exact stock quantities | USDC received selling those quantities |
| ---: | ---: | ---: |
| 10 | 9.998468 | 9.988447 |
| 100 | 99.984773 | 99.884784 |
| 1,000 | 999.848219 | 998.847657 |

Buy and sell quotes are independent calls against the same starting block, not consecutive legs of a simulated round trip. Values exclude gas and are relative to the published oracle reference (which can be stale), not an assertion of current fair value. Per-component raw quantities and quote results are in the manifest. An `eth_call` quoter result does not prove that a funded user can complete a seven-swap atomic gateway transaction, including all issuer policy checks.

Both stock and USDC feeds have published 24-hour heartbeats. Stock reference values also stop updating outside market sessions. The controller's execution policy requires:
- every stock update at most **25 hours** old (heartbeat liveness);
- at least one stock update at most **1 hour** old, as evidence the market is trading;
- USDC at most **25 hours** old;
- a **1-hour** sequencer recovery grace period;
- weekdays **15:00–20:00 UTC**.

A quiet feed inside its 0.5% deviation band is still accurate, so it no longer blocks execution. Holidays fail closed unless a heartbeat lands on them. The planner's per-leg oracle minimums and bounded step limit what a stale-but-accepted price can cost. Quantity-based basket mint/redeem does not use these reference prices. The captured block falls outside the execution window, and the read preflight correctly reports a reset ineligible.

`scripts/feed_availability.py` replays past windows from each feed's round history. For the ten weekdays from 2026-09-14 to 2026-09-25 (Base block 51,835,998), in ten-minute slots:

| Rule | Usable slots | Weekdays with no usable slot |
| --- | ---: | ---: |
| Original: every stock ≤1 h, 15:00–17:00 UTC | 1 of 120 | 9 of 10 |
| Current: every stock ≤25 h and one ≤1 h, 15:00–20:00 UTC | 288 of 300 | 0 of 10 |

Registry pauses and sequencer outages are not replayed. [Feed behavior](https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase), [USDC feed directory](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json), [sequencer guidance](https://docs.chain.link/data-feeds/l2-sequencer-feeds)

## Native Base fork tests

`test/BaseFork.t.sol` runs the current contracts against live Base state with native B20 execution. On 2026-09-28 (UTC) all four tests passed on the remediated code with base-anvil `nightly-98e7839c65f6` (base/base `3eb4817`, binaries checked with `gh attestation verify`), under both precompile rule sets: Beryl, which mainnet runs until 2026-09-30 18:00 UTC, and Cobalt after that. Figures are from the Cobalt-rule run, at blocks **51,894,041** to **51,894,088**. Each test creates USDC only in local fork storage and acquires every B20 through its actual Slipstream pool. No B20 balance or code is fabricated, and nothing is broadcast.

- **Round trip** (`testBaseNativeB20BootstrapAndUSDCRoundTrip`). A seed of 100 USDC per stock, an equal-dollar fixture, bootstrapped the vault. The fee-free gateway minted 100 M7 for **70.000054 USDC** and redeemed them for **69.930015 USDC**; the difference is pool pricing. Assertions cover shares, refunds, the vault's backing, the gateway holding nothing afterwards, and cleared allowances.
- **Reset** (`testBaseNativeResetToEqualWeightsThroughLivePools`). A seed holding twice as much AAPLc by value as each other stock is reset to equal weights through the live pinned pools, in the next weekday execution window, including the check of each pool against its 10-minute average. Feeds are mocked only to report their fork-time answers as fresh. At block 51,894,072 one tranche made seven trades using 1.29M gas: it sold $127.95 of AAPLc and bought $128.02 of the other six, and paid the caller a $0.064 reward, 5 bp of the value traded. The vault's $1,199.95 became $1,200.11 including the reward: the pools filled slightly better than the oracle.
- **Price per share** (`testBaseNativeLensPricesShares`). `M7Lens` values a seed bought for 700 USDC at **$0.7002** per share from the live feeds, while its stalest price was 18 hours old.
- **Policies and exits** (`testBaseNativeTransferGasAndResilientRedemption`). M7 transfers against the real policy registry cost about 52k gas to a new holder and 28k to an existing one. These are measured inside one test transaction; a standalone transfer also pays cold account access. `redeemBasketWithClaims` delivered every leg, with no claims.

`script/rehearse.sh` also ran the mainnet runbook end to end on a local base-anvil fork under both rule sets:
- deploy, and 63 deployment checks with bytecode matching the build;
- an equal-dollar seed worth 1,000 USDC at oracle prices, bought for 999.74 USDC;
- bootstrap, and 84 post-bootstrap checks;
- gateway and in-kind smoke tests;
- the reset status check and the monitor;
- the first reset with the runbook's `Rebalance` script. The rehearsal ran outside the execution window, so the valuation refused it (`OutsideExecutionWindow`) and nothing changed.

The third review's live-pool regressions (`test/Audit3Fork.t.sol`) also pass under both rule sets, at the blocks the review recorded its findings. A sandwich of the reset no longer pays: each attempt that executed lost the attacker money, and larger pushes were refused. A $182k TSLAc sale completes in 19 tranches, and a $900k vault with two stocks 42% under target in 15.

An earlier, cap-weighted design's round trip had passed at block 51,830,602 with base-anvil v1.1.0. The machine-readable record is `config/base.json` → `native_fork_verification`. The tests are opt-in (`BASE_FORK_TEST=true`, `FOUNDRY_BASE=beryl|cobalt`) and need the Base-specific `forge`; the ordinary suite skips them. Still unvalidated: production addresses, anything with live funds, and the runbook's reset script inside a live execution window.

## Reproduce and complete acceptance

With Python 3.9+ and Foundry `cast` installed:

```sh
python3 scripts/verify_base.py
python3 scripts/verify_base.py --rpc "$BASE_RPC_URL" --reads-only --account 0xYOUR_VAULT --account 0xYOUR_GATEWAY
python3 -m unittest discover -s test -p 'test_*.py'
```

The second command requires real addresses. Every onchain read is pinned to one block. The script requires Base chain ID 8453, validates identities and decimals, reads issuer pauses and policies, checks pool identity, liquidity and router factories, and quotes equal-dollar baskets in both directions. Unknown, invalid, or failed reads exit nonzero; without `--reads-only`, prices unusable for a reset also exit nonzero. JSON always includes `launch_ready: false`, because no collection of these read checks establishes full production readiness. Default RPC is `https://base-rpc.publicnode.com`; a configured authenticated provider is preferable for repeated monitoring.

Before seeding, complete the gates in [the deployment runbook](DEPLOYMENT.md):

1. Re-run the native tests and `script/rehearse.sh` on a post-Cobalt block, then verify the deployment with `scripts/verify_deployment.py` before funding it.
2. Establish the permitted wrapper distribution and issuer eligibility. The owner has decided to launch without an independent security review.
3. Run `scripts/monitor.py` on an always-on server and test its alerting. Public CLI reads alone are not a continuously running monitor.
4. Re-run current source verification and read checks immediately before any deployment or bootstrap. Passing historical quotes does not reserve liquidity.

No dedicated M7/USDC liquidity pool is required. Fees paid to existing pools, deployment gas and monitoring are the only other costs. The precision reserve permanently locks 10 of the initial 1,000 M7 shares, 1% of the seed. The bootstrap must hold at least 0.01 of every stock token to satisfy the minimum projected reserve of 10,000 raw units per stock, about $53 of seed at current prices. The [third internal review](AUDIT-3.md) covers the current code, including the reset's capacity through these pools; the [first](AUDIT.md) and [second](AUDIT-2.md) cover the earlier design.
