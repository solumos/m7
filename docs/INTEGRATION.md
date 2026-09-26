# Base integration evidence and launch gates

`config/base.json` pins canonical assets and integrations with primary-source URLs. Its `verification` field records a read-only onchain snapshot at Base block **51,830,549**, hash `0xf823c24396bac6cfacb24c8d46a6e3c3555e121bbdfa9b88af2beaa2fcb1f23b`, timestamp **2026-09-26 19:20:45 UTC**. It is historical evidence, not deployment approval. No wallet was used and no live transaction was signed, funded, or broadcast. A subsequent local Base fork executed the full stock acquisition, bootstrap, and gateway round trip, as recorded below.

## Verified integrations

All seven [Coinbase-issued stock records](https://api.coinbase.com/v1/tokenized-stocks) matched the [official Base list](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks), with 8 token decimals and 8 feed decimals. Onchain calls confirmed positive token supply, unpaused transfers, live issuer multipliers, and unpaused issuer reference feeds. Token names/symbols are mutable; contract integrations use addresses.

The stocks are B20 native precompiles and have no ordinary bytecode. Never reject them with `address.code.length == 0`. Standard ERC-20 calls, exact balance-delta checks, and Base-aware execution are required. Ordinary Anvil forks may not implement the B20 precompile. The native integration test used Base's patched Foundry build; the ordinary mocked unit suite alone does not establish native compatibility. [B20 integration notes](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks)

All seven direct USDC pairs exist with active liquidity at tick spacing **10** on Aerodrome's gauges V3 factory. The router and quoter both report that same factory. Initial and gauge-caps factories were also probed across tick spacings 1, 10, 50, 100, 200, 500, and 2000; no stock pairs were found there. Chosen deployments come from the [Aerodrome repository](https://github.com/aerodrome-finance/slipstream#deployments).

| Integration | Address |
| --- | --- |
| Slipstream factory | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` |
| Swap router | `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F` |
| Quoter | `0x514c8B5f54112481E28028F1166Bd78501089259` |
| Coinbase oracle registry | `0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD` |
| B20 policy registry | `0x8453000000000000000000000000000000000002` |
| UMA OOv3 | `0x2aBf1Bd76655de80eDB3086114315Eec75AF500c` |

The issuer oracle registry's verified ABI has `getOracleParams(address) -> (uint256 multiplier, bool paused)`. The actual onchain read succeeded for all seven tokens. Transfer sender, receiver, and executor policy IDs were all 5 at the observation block, and the selected pools, router, and quoter were authorized for those policies. Future vault/gateway/holder addresses must be checked individually: a public pool's authorization does not establish theirs. Policies may change. [Verified registry source](https://base.blockscout.com/api/v2/smart-contracts/0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD), [B20 interfaces](https://github.com/base/base-std/blob/main/src/interfaces/IB20.sol)

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

Both stock and USDC feeds have published 24-hour heartbeats. Stock reference values also stop updating outside market sessions. The controller's conservative execution policy requires stock updates within **1 hour**, USDC within **25 hours**, and a **1-hour** sequencer recovery grace period. Thus a valid but old stock reference price blocks rebalancing, including much of a weekend or quiet session. Quantity-based basket mint/redeem does not use these reference prices. At this captured weekend block, the stock freshness gate fails, and the read preflight correctly reports rebalance ineligible. [Feed behavior](https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase), [USDC feed directory](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json), [sequencer guidance](https://docs.chain.link/data-feeds/l2-sequencer-feeds)

## Native Base fork round trip

`test/BaseFork.t.sol:testBaseNativeB20BootstrapAndUSDCRoundTrip` passed at Base block **51,830,602** using the official [Base Foundry v1.1.0 build](https://github.com/base/base-anvil). This is an execution test on a local fork, distinct from the historical read-only quote snapshot above. The test created 2,000 USDC solely in local fork storage; it acquired every B20 token through its actual live-state Slipstream pool and used native B20 transfer behavior. No B20 balance or code was fabricated, and no live funds or transactions were used.

The test spent 100 USDC per constituent as an **equal-dollar fixture**, bootstrapped the deployed vault code with those seven purchases, then minted 100 M7CAP shares for **70.000034 USDC** and redeemed them for **69.929989 USDC** through the gateway. Assertions verified share mint/burn, refund reconciliation, preservation of the original vault backing, zero gateway balances, and cleared gateway allowances. This proves the exercised native seven-pool route and accounting path at that block. It does not establish the intended market-cap weights or production deployment addresses.

A second native fork test exercised the actual deployed UMA OOv3 using `ASSERT_TRUTH2`. It checked real assertion metadata, a 500 USDC minimum bond, a 1,000 USDC supplied bond, the 72-hour challenge window, rejection of early settlement, permissionless acceptance after advancing local fork time, and refund of the full 1,000 USDC bond. Only USDC funding and time changed in the local fork; there were no oracle mocks or whitelist modifications. Its claim and ratios were explicitly synthetic test fixtures, not a proposed market-cap observation. The cross-chain disputed-resolution path and native-stock rebalance execution still require integration acceptance.

The machine-readable evidence is `config/base.json` → `native_fork_verification`. The fork test is opt-in (`BASE_FORK_TEST=true`, `FOUNDRY_BASE=true`) and must use the Base-specific `forge` binary with a Base RPC and `BASE_FORK_BLOCK=51830602` to reproduce this observation. Running the ordinary test suite skips this native-only integration test.

## Reproduce and complete acceptance

With Python 3.9+ and Foundry `cast` installed:

```sh
python3 scripts/verify_base.py
python3 scripts/verify_base.py --rpc "$BASE_RPC_URL" --snapshot snapshot.json --account 0xYOUR_VAULT --account 0xYOUR_GATEWAY
python3 -m unittest discover -s test -p 'test_*.py'
```

The second command requires real addresses and the output of `index_snapshot.py`; the placeholder strings intentionally cannot be submitted. `--snapshot` uses that snapshot's human quantity ratios valued at the current feed snapshot to apportion the liquidity probes. It does not validate company capitalization evidence. Every onchain read is pinned to one block. The script requires Base chain ID 8453, validates identities/decimals, reads issuer pauses/policies, checks pool identity/liquidity and router factories, verifies the explicit UMA identifier/collateral through current Finder allowlists and post-sync bond requirements, and obtains both quote directions. Unknown, invalid, or failed reads exit nonzero; stale prices also exit nonzero. JSON always includes `launch_ready: false`, because no collection of these read checks establishes full production readiness. Default RPC is `https://base-rpc.publicnode.com`; a configured authenticated provider is preferable for repeated monitoring.

Before seeding approximately $1,000, complete:

1. Produce and independently review sourced quarter-end observations and the bootstrap basket; exercise the actual market-cap allocation with `--snapshot`.
2. Repeat the successful local native-fork test with the reviewed market-cap bootstrap allocation and final deployment configuration/addresses, then validate production readiness. Extend native integration coverage to issuer policy rejection, full rollback, the disputed UMA path, and stock rebalance execution. The current native test covers USDC/raw-stock decimal conversion, approvals, seven-stock mint, refund, redemption, and cleared allowances.
3. Complete independent security review of the custom contracts and deployment parameters, establish the permitted wrapper distribution and issuer eligibility, and publish the immutable methodology/evidence.
4. Fund and operate independent UMA proposal/dispute monitoring; test alerting and recovery before the first assertion. Public CLI reads alone are not a continuously running monitor.
5. Re-run current source verification and read checks immediately before any deployment or bootstrap. Passing historical quotes does not reserve liquidity.

No dedicated M7CAP/USDC liquidity pool is required. The ~$1,000 is seed backing; fees paid to existing pools, deployment gas, audits, monitoring, and oracle bonds are additional costs. The precision reserve permanently locks 10 of the initial 1,000 M7CAP shares (about $10 of a $1,000 seed). The reviewed bootstrap must hold at least 0.01 of every stock token to satisfy the minimum projected reserve of 10,000 raw units per stock. See the [internal audit](AUDIT.md) for the rounding fix and remaining findings.
