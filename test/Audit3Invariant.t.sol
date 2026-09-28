// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {ControllerFeed, ControllerRegistry} from "./mocks/ControllerMocks.sol";
import {B20PolicyMixin, PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {PricedVenue} from "./mocks/RouterMocks.sol";

/// @dev A stock or USDC double the issuer can freeze (every transfer reverts) or seize from (burn).
contract Audit3Token is ERC20, B20PolicyMixin {
    uint8 private immutable _decimals;
    bool public frozen;

    constructor(uint8 decimals_) ERC20("Audit3 token", "A3") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function seize(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setFrozen(bool value) external {
        frozen = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) require(!frozen, "frozen");
        super._update(from, to, amount);
    }
}

/// @dev Random issuance, exits, claims, donations, seizures, freezes, price and venue moves, and quarterly resets
///      through the real vault, controller and valuation. Violations latch in ghost flags.
contract Audit3Handler is Test {
    uint256 constant WAD = 1e18;
    address constant KEEPER = address(0xBEEF);

    M7Vault public vault;
    IndexController public controller;
    Valuation public valuation;
    PricedVenue public venue;
    Audit3Token[8] public tokens;
    ControllerFeed[8] public feeds;
    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];

    uint256[8] public lastBacking;
    uint256 public lastSupply;

    bool public backingFellOutsideResetOrSeizure;
    bool public rewardAboveBound;
    bool public supplyChangedByReset;
    bool public secondResetInAQuarter;
    bool public resetLossAboveBound;
    bool public resetLeftExcessCash;
    bool public resetNotEqualAfterFullStep;
    bool public resetTouchedClaims;
    bool public legAboveCap;
    bool public tradedThroughMovedPool;

    uint256 public resetsSucceeded;
    uint256 public resetsTraded;
    uint256 public resetsReverted;
    uint256 public repeatResetsRefused;
    uint256 public rewardsWithoutTrades;
    uint256 public fullStepChecks;
    uint256 public partialSteps;
    uint256 public poolMovedRefusals;
    bytes[] public revertReasons;
    mapping(bytes32 => uint256) public revertCount;

    constructor(
        M7Vault vault_,
        IndexController controller_,
        PricedVenue venue_,
        Audit3Token[8] memory tokens_,
        ControllerFeed[8] memory feeds_
    ) {
        vault = vault_;
        controller = controller_;
        valuation = controller_.valuation();
        venue = venue_;
        tokens = tokens_;
        feeds = feeds_;
        _record();
    }

    // ------------------------------------------------------------------ holder and issuer actions

    function mintInKind(uint256 actorSeed, uint256 shares) external {
        address who = actors[actorSeed % 3];
        // Each mint may double the supply; stop growing before balances overflow over long sequences.
        if (vault.totalSupply() > 1e33) return;
        shares = bound(shares, 1e15, vault.totalSupply());
        try vault.quoteMint(shares) returns (uint256[8] memory amounts) {
            for (uint256 i; i < 8; ++i) {
                tokens[i].mint(who, amounts[i]);
                vm.prank(who);
                tokens[i].approve(address(vault), amounts[i]);
            }
            vm.prank(who);
            try vault.mintBasket(shares, amounts, who, block.timestamp) {} catch {}
        } catch {}
        _check();
    }

    function redeemInKind(uint256 actorSeed, uint256 shares) external {
        address who = actors[actorSeed % 3];
        uint256 cap = Math.min(vault.balanceOf(who), vault.totalSupply() - vault.LOCKED_SHARES());
        if (cap == 0) return;
        uint256[8] memory none;
        vm.prank(who);
        try vault.redeemBasket(bound(shares, 1, cap), none, who, block.timestamp) {} catch {}
        _check();
    }

    function redeemWithClaims(uint256 actorSeed, uint256 shares) external {
        address who = actors[actorSeed % 3];
        uint256 cap = Math.min(vault.balanceOf(who), vault.totalSupply() - vault.LOCKED_SHARES());
        if (cap == 0) return;
        uint256[8] memory none;
        vm.prank(who);
        vault.redeemBasketWithClaims(bound(shares, 1, cap), none, who, block.timestamp);
        _check();
    }

    function withdrawClaim(uint256 actorSeed, uint256 index, uint256 amount) external {
        address who = actors[actorSeed % 3];
        index = index % 8;
        uint256 owed = vault.claimOf(who)[index];
        if (owed == 0) return;
        vm.prank(who);
        try vault.withdrawClaim(index, bound(amount, 1, owed), who) {} catch {}
        _check();
    }

    function donate(uint256 index, uint256 bps) external {
        index = index % 8;
        if (vault.backing(index) > 1e33) return;
        uint256 amount =
            Math.max(vault.backing(index), index == 7 ? 1e6 : 1e8) * bound(bps, 1, 5_000) / 10_000;
        tokens[index].mint(address(vault), amount);
        _check();
    }

    /// An issuer seizure of vault holdings: the one action besides a reset that may lower backing per share.
    function seize(uint256 index, uint256 bps) external {
        index = index % 7;
        uint256 amount = vault.backing(index) * bound(bps, 1, 5_000) / 10_000;
        if (amount == 0) return;
        tokens[index].seize(address(vault), amount);
        _record();
    }

    function toggleFreeze(uint256 index) external {
        index = index % 8;
        tokens[index].setFrozen(!tokens[index].frozen());
    }

    function unfreezeAll() external {
        for (uint256 i; i < 8; ++i) {
            tokens[i].setFrozen(false);
        }
    }

    /// Moves a stock's oracle price by up to 30% (kept within $20-$500) and sets its venue price up to 30 bp away.
    function movePrice(uint256 index, uint256 moveSeed, uint256 offsetSeed) external {
        index = index % 7;
        uint256 price = uint256(feeds[index].answer());
        price = price * bound(moveSeed, 7_000, 13_000) / 10_000;
        price = Math.min(Math.max(price, 20e8), 500e8);
        feeds[index].set(int256(price), block.timestamp);
        uint256 offset = bound(offsetSeed, 9_970, 10_030);
        venue.setRate(address(tokens[index]), price * 1e8 * offset / 10_000);
    }

    /// The venue's fee and impact on each trade, up to 40 bp: inside the reset's 1% minimum even with the offset.
    function setVenueHaircuts(uint256 sellBps, uint256 buyBps) external {
        venue.setHaircuts(bound(sellBps, 0, 40), bound(buyBps, 0, 40));
    }

    /// Arbitrage returns every pool to its 10-minute average.
    function calmPools() external {
        venue.setTicks(venue.averageTick(), venue.averageTick());
    }

    /// Someone pushes the pools: every stock's pool tick sits up to 50 ticks from its 10-minute average.
    function pushPools(uint256 spotSeed, uint256 averageSeed) external {
        int24 average = int24(int256(bound(averageSeed, 0, 200_000)) - 100_000);
        venue.setTicks(average + int24(int256(bound(spotSeed, 0, 100)) - 50), average);
    }

    // ------------------------------------------------------------------ the quarterly reset

    /// Travels 1-120 days to a weekday 16:00 UTC, reports every feed fresh, and resets. Optionally tries a second reset
    /// in the same quarter, which must be refused.
    function reset(uint256 daysSeed, bool tryAgain) external {
        uint256 t = (block.timestamp / 1 days + bound(daysSeed, 1, 120)) * 1 days + 16 hours;
        while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) {
            t += 1 days;
        }
        vm.warp(t);
        for (uint256 i; i < 8; ++i) {
            feeds[i].set(feeds[i].answer(), t);
        }
        if (_reset() && tryAgain) {
            try controller.rebalance(block.timestamp, KEEPER) {
                secondResetInAQuarter = true;
            } catch {
                ++repeatResetsRefused;
            }
        }
    }

    /// The next tranche half an hour later, or at the next weekday's 15:00 UTC if that leaves the window.
    function nextTranche() external {
        uint256 t = block.timestamp + controller.TRANCHE_COOLDOWN();
        if (t % 1 days < 15 hours) t = t / 1 days * 1 days + 15 hours;
        if (t % 1 days >= 20 hours) t = (t / 1 days + 1) * 1 days + 15 hours;
        while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) {
            t += 1 days;
        }
        vm.warp(t);
        for (uint256 i; i < 8; ++i) {
            feeds[i].set(feeds[i].answer(), t);
        }
        _reset();
    }

    struct Before {
        uint256[8] prices;
        uint256[8] reserved;
        uint256 nav;
        uint256 supply;
        uint256 keeper;
        uint256 calls;
        uint256 cash;
        bool due;
    }

    function _reset() private returns (bool ok) {
        Before memory b;
        b.cash = vault.backing(7);
        b.due = !controller.executedQuarter(controller.currentQuarter());
        b.prices = valuation.snapshot();
        b.nav = _nav(b.prices);
        b.supply = vault.totalSupply();
        b.reserved = _reserved();
        b.keeper = tokens[7].balanceOf(KEEPER);
        b.calls = venue.callCount();
        vm.recordLogs();
        try controller.rebalance(block.timestamp, KEEPER) {
            ok = true;
            ++resetsSucceeded;
            _afterReset(b);
            if (_completed(vm.getRecordedLogs())) _checkEqual(b.prices);
            else ++partialSteps;
        } catch (bytes memory reason) {
            ++resetsReverted;
            if (bytes4(reason) == IndexController.PoolMoved.selector) ++poolMovedRefusals;
            if (revertCount[keccak256(reason)]++ == 0) revertReasons.push(reason);
        }
        _record();
    }

    function _afterReset(Before memory b) private {
        if (!b.due) secondResetInAQuarter = true;
        if (vault.totalSupply() != b.supply) supplyChangedByReset = true;
        uint256[8] memory reservedAfter = _reserved();
        for (uint256 i; i < 8; ++i) {
            if (reservedAfter[i] != b.reserved[i] || tokens[i].balanceOf(address(vault)) < reservedAfter[i]) {
                resetTouchedClaims = true;
            }
        }
        uint256 reward = tokens[7].balanceOf(KEEPER) - b.keeper;
        uint256 rewardValue = reward * b.prices[7] / 1e6;
        (uint256 traded, uint256 legs) = _traded(b.prices, b.calls);
        // 5 bp of the one-way traded value, at most $25; `traded` counts both ways, so this bound has room.
        if (rewardValue > Math.min(traded * 5 / 10_000, 25e18) + b.prices[7] / 1e6) rewardAboveBound = true;
        if (legs != 0) ++resetsTraded;
        else if (reward != 0) ++rewardsWithoutTrades;
        uint256 navAfter = _nav(b.prices);
        uint256 slack = legs * Math.max(b.prices[7] / 1e6, _maxStockUnitValue(b.prices)) + 8;
        if (navAfter + traded / 100 + rewardValue + slack < b.nav) resetLossAboveBound = true;
        // Cash never grows beyond what was there plus the cap: a tranche invests its share and holds back the rest.
        uint256 cap = Math.max(navAfter / 10_000, 7 * 1e4 * b.prices[7] / 1e6);
        if (vault.backing(7) * b.prices[7] / 1e6 > Math.max(cap, b.cash * b.prices[7] / 1e6) + cap) {
            resetLeftExcessCash = true;
        }
    }

    /// When a reset completes, stocks clearly above the precision floor hold equal value within the deadband, plus the
    /// venue's pricing noise and $0.02 for skipped dust legs and rounding; cash is within its cap.
    function _checkEqual(uint256[8] memory prices) private {
        ++fullStepChecks;
        uint256 nav = _nav(prices);
        if (vault.backing(7) * prices[7] / 1e6 > Math.max(nav / 10_000, 7 * 1e4 * prices[7] / 1e6)) {
            resetLeftExcessCash = true;
        }
        uint256 floorUnits = Math.mulDiv(
            vault.MIN_LOCKED_STOCK_UNITS(), vault.totalSupply(), vault.LOCKED_SHARES(), Math.Rounding.Ceil
        );
        uint256 low = type(uint256).max;
        uint256 high;
        for (uint256 i; i < 7; ++i) {
            uint256 held = vault.backing(i);
            if (held <= 3 * floorUnits) continue;
            uint256 value = held * prices[i] / 1e8;
            low = Math.min(low, value);
            high = Math.max(high, value);
        }
        if (high != 0 && high > low * 10_031 / 10_000 + 0.02e18) resetNotEqualAfterFullStep = true;
    }

    function _completed(Vm.Log[] memory logs) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IndexController.Rebalanced.selector) {
                (,,,,,, bool completed) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, bool));
                return completed;
            }
        }
        return false;
    }

    /// Oracle value of everything the vault sold or spent during the reset, from the venue's own call log. Each sale
    /// must be within the $10k cap, and each purchase within it plus 1% for sales filled above the oracle. No stock may
    /// trade through a pool pushed more than 25 ticks against the vault.
    function _traded(uint256[8] memory prices, uint256 from) private returns (uint256 traded, uint256 legs) {
        for (uint256 k = from; k < venue.callCount(); ++k) {
            PricedVenue.Call memory c = venue.callAt(k);
            ++legs;
            bool buying = c.tokenIn == address(tokens[7]);
            for (uint256 i; i < 7; ++i) {
                if (address(tokens[i]) != (buying ? c.tokenOut : c.tokenIn)) continue;
                uint256 value = buying ? c.amountIn * prices[7] / 1e6 : c.amountIn * prices[i] / 1e8;
                traded += value;
                if (value > (buying ? 10_100e18 : 10_000e18)) legAboveCap = true;
                int256 dearer = address(tokens[7]) < address(tokens[i])
                    ? int256(venue.averageTick()) - venue.spotTick()
                    : int256(venue.spotTick()) - venue.averageTick();
                if (buying ? dearer > 25 : -dearer > 25) tradedThroughMovedPool = true;
            }
        }
    }

    // ------------------------------------------------------------------ bookkeeping

    function _nav(uint256[8] memory prices) private view returns (uint256 nav) {
        uint256[8] memory held;
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
        (, nav) = valuation.values(held, prices);
    }

    function _maxStockUnitValue(uint256[8] memory prices) private pure returns (uint256 unit) {
        for (uint256 i; i < 7; ++i) {
            unit = Math.max(unit, prices[i] / 1e8 + 1);
        }
    }

    function _reserved() private view returns (uint256[8] memory amounts) {
        for (uint256 i; i < 8; ++i) {
            amounts[i] = vault.reserved(i);
        }
    }

    function _record() private {
        for (uint256 i; i < 8; ++i) {
            lastBacking[i] = vault.backing(i);
        }
        lastSupply = vault.totalSupply();
    }

    /// Backing per share never falls through issuance, exits, claims, donations or freezes.
    function _check() private {
        uint256 supply = vault.totalSupply();
        for (uint256 i; i < 8; ++i) {
            if (vault.backing(i) * lastSupply < lastBacking[i] * supply) {
                backingFellOutsideResetOrSeizure = true;
            }
        }
        _record();
    }

    function revertReasonCount() external view returns (uint256) {
        return revertReasons.length;
    }

    function knownClaims(uint256 index) external view returns (uint256 total) {
        for (uint256 a; a < 3; ++a) {
            total += vault.claimOf(actors[a])[index];
        }
    }

    function knownShares() external view returns (uint256 total) {
        for (uint256 a; a < 3; ++a) {
            total += vault.balanceOf(actors[a]);
        }
        total += vault.balanceOf(vault.SEED_LOCK());
    }
}

/// @dev Third review (docs/AUDIT-3.md): the first campaign to interleave quarterly resets with every holder flow,
///      seizures, freezes, and price and venue moves.
contract Audit3InvariantTest is Test {
    Audit3Handler handler;
    M7Vault vault;

    function setUp() public {
        vm.warp(1790870400); // Thursday Oct 1 2026 16:00 UTC
        Audit3Token[8] memory tokens;
        ControllerFeed[8] memory feeds;
        address[8] memory addresses;
        IAggregatorV3[8] memory aggregators;
        IERC20[8] memory assets;
        for (uint256 i; i < 8; ++i) {
            tokens[i] = new Audit3Token(i == 7 ? 6 : 8);
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(100e8));
            addresses[i] = address(tokens[i]);
            aggregators[i] = feeds[i];
            assets[i] = IERC20(addresses[i]);
        }
        Valuation valuation = new Valuation(
            addresses, aggregators, new ControllerFeed(0, 0), new ControllerRegistry(), 25 hours
        );
        PricedVenue venue = new PricedVenue(addresses[7]);
        int24[7] memory spacings;
        for (uint256 i; i < 7; ++i) {
            spacings[i] = 10;
            venue.setPool(addresses[i], addresses[7], 10, true);
            venue.setRate(addresses[i], 100e8 * 1e8); // $100: 1 raw stock unit buys 1 raw USDC unit
        }
        PolicyRegistryMock registry = new PolicyRegistryMock();
        address predicted = vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        IndexController controller = new IndexController(IM7Vault(predicted), valuation);
        vault = new M7Vault(assets, spacings, address(controller), venue, venue, registry, address(this));
        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            tokens[i].mint(address(venue), 1e30);
            if (i < 7) {
                seed[i] = 100e8 + i * 12_345; // $70,000 in uneven raw amounts
                tokens[i].mint(address(this), seed[i]);
                tokens[i].approve(address(vault), seed[i]);
            }
        }
        vault.bootstrap(seed, address(0xA1));
        handler = new Audit3Handler(vault, controller, venue, tokens, feeds);
        targetContract(address(handler));
    }

    function invariant_audit3HolderAccounting() public view {
        assertFalse(
            handler.backingFellOutsideResetOrSeizure(), "per-share backing fell outside a reset or seizure"
        );
        assertEq(handler.knownShares(), vault.totalSupply(), "untracked shares");
        for (uint256 i; i < 8; ++i) {
            assertEq(handler.knownClaims(i), vault.reserved(i), "claims differ from reserved");
        }
    }

    function invariant_audit3ResetBounds() public view {
        assertFalse(handler.rewardAboveBound(), "reward above min(5 bp of the traded value, $25)");
        assertFalse(handler.supplyChangedByReset(), "a reset changed the share supply");
        assertFalse(handler.secondResetInAQuarter(), "a tranche after completion or inside the cooldown");
        assertFalse(handler.resetLossAboveBound(), "reset loss above 1% of traded value plus the reward");
        assertFalse(handler.resetLeftExcessCash(), "reset left cash above its cap");
        assertFalse(handler.resetNotEqualAfterFullStep(), "a completed reset left unequal weights");
        assertFalse(handler.legAboveCap(), "a trade above the $10k cap");
        assertFalse(handler.tradedThroughMovedPool(), "a trade through a pool pushed against the vault");
        assertFalse(handler.resetTouchedClaims(), "a reset changed or underfunded deferred claims");
    }

    /// A wrong oracle price cannot make the vault trade at that price: each leg's minimum is computed from the same
    /// price, so a 5% error in either direction fails the leg and the whole reset rolls back.
    function testAudit3WrongPricesFailClosedAgainstTheRealVault() public {
        Audit3Handler h = handler;
        IndexController controller = h.controller();
        for (uint256 k; k < 2; ++k) {
            uint256 snap = vm.snapshotState();
            h.movePrice(0, k == 0 ? 10_500 : 9_500, 10_000); // oracle AAPL moves 5%...
            h.venue().setRate(address(h.tokens(0)), 100e8 * 1e8); // ...but the pool still trades at $100
            vm.expectRevert(bytes("Too little received"));
            controller.rebalance(block.timestamp, address(0xBEEF));
            assertTrue(controller.rebalanceDue());
            vm.revertToState(snap);
        }
    }

    /// One long seeded sequence with aggregate reset statistics; the invariant campaign explores the same actions.
    function testAudit3ResetSoak() public {
        uint256 seed = vm.envOr("AUDIT3_SOAK_SEED", uint256(42));
        uint256 steps = vm.envOr("AUDIT3_SOAK_STEPS", uint256(3_000));
        for (uint256 k; k < steps; ++k) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            (uint256 action, uint256 a, uint256 b, uint256 c) =
                (seed % 100, seed >> 8, seed >> 72, seed >> 136);
            if (action < 15) handler.mintInKind(a, b);
            else if (action < 25) handler.redeemInKind(a, b);
            else if (action < 35) handler.redeemWithClaims(a, b);
            else if (action < 40) handler.withdrawClaim(a, b, c);
            else if (action < 45) handler.donate(a, b % 500);
            else if (action < 47) handler.seize(a, b % 1_000);
            else if (action < 48) handler.toggleFreeze(a);
            else if (action < 53) handler.unfreezeAll();
            else if (action < 75) handler.movePrice(a, b, c);
            else if (action < 77) handler.setVenueHaircuts(a, b);
            else if (action < 78) handler.pushPools(a, b);
            else if (action < 80) handler.calmPools();
            else if (action < 90) handler.nextTranche();
            else handler.reset(a, b % 2 == 0);
        }
        afterInvariant();
        for (uint256 i; i < handler.revertReasonCount(); ++i) {
            bytes memory reason = handler.revertReasons(i);
            emit log_named_uint(
                string.concat("  revert ", vm.toString(reason)), handler.revertCount(keccak256(reason))
            );
        }
        invariant_audit3HolderAccounting();
        invariant_audit3ResetBounds();
        assertGt(handler.resetsTraded(), 10, "the soak exercised trading resets");
    }

    function afterInvariant() public {
        emit log_named_uint("resets succeeded", handler.resetsSucceeded());
        emit log_named_uint("  of which traded", handler.resetsTraded());
        emit log_named_uint("  completions checked for equal weight", handler.fullStepChecks());
        emit log_named_uint("  rewards paid without a trade", handler.rewardsWithoutTrades());
        emit log_named_uint("  partial tranches", handler.partialSteps());
        emit log_named_uint("  pool-moved refusals", handler.poolMovedRefusals());
        emit log_named_uint("resets reverted", handler.resetsReverted());
        emit log_named_uint("repeat resets refused", handler.repeatResetsRefused());
    }
}
