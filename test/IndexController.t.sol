// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";
import {Swap} from "../src/Types.sol";
import {
    ControllerToken,
    ControllerFeed,
    ControllerRegistry,
    ControllerOracle,
    ControllerVault
} from "./mocks/ControllerMocks.sol";

contract IndexControllerTest is Test {
    IndexController controller;
    Valuation valuation;
    ControllerVault vault;
    ControllerOracle oracle;
    ControllerToken bond;
    address[8] assets;
    ControllerFeed[8] feeds;
    ControllerFeed sequencer;
    ControllerRegistry registry;
    uint256[7] ratios;
    uint32 constant QUARTER = 2026 * 4 + 3;
    bytes32 constant DIGEST = keccak256("canonical observation bytes");
    string constant EVIDENCE = "ipfs://bafyevidence";
    string constant METHODOLOGY = "ipfs://bafymethodology";

    function setUp() public {
        vm.warp(1790870400); // Thursday Oct 1 2026 16:00 UTC.
        IAggregatorV3[8] memory aggregators;
        for (uint256 i; i < 8; ++i) {
            assets[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(100e8));
            aggregators[i] = feeds[i];
            if (i < 7) ratios[i] = uint256(1e18) / 7;
        }
        ratios[6] += 1e18 % 7;
        sequencer = new ControllerFeed(0, 0);
        registry = new ControllerRegistry();
        valuation = new Valuation(assets, aggregators, sequencer, registry, 25 hours);
        vault = new ControllerVault(assets, feeds);
        for (uint256 i; i < 7; ++i) {
            ControllerToken(assets[i]).mint(address(vault), 100e8);
        }
        oracle = new ControllerOracle();
        bond = new ControllerToken(6);
        controller = new IndexController(
            IM7CapVault(address(vault)), oracle, bond, 600e6, keccak256("methodology"), METHODOLOGY, valuation
        );
        bond.mint(address(this), 10000e6);
        bond.approve(address(controller), type(uint256).max);
    }

    function _propose() private returns (bytes32) {
        return controller.propose(QUARTER, ratios, EVIDENCE, DIGEST);
    }

    function _accept() private returns (bytes32 id) {
        id = _propose();
        vm.warp(1791216000); // Monday Oct 5 16:00 UTC, 96h later.
        _refresh();
        assertTrue(controller.settle(id));
    }

    function _refresh() private {
        for (uint256 i; i < 8; ++i) {
            feeds[i].set(i == 7 ? int256(1e8) : int256(100e8), block.timestamp);
        }
        sequencer.set(0, block.timestamp);
    }

    /// Stock 0 +3.5% and stock 1 -3.5% in quantity: inside one quarter's 5% step.
    function _shift() private {
        ratios[0] += 0.005e18;
        ratios[1] -= 0.005e18;
    }

    function _execute() private {
        controller.execute(block.timestamp);
    }

    function _held(uint256 index) private view returns (uint256) {
        return ControllerToken(assets[index]).balanceOf(address(vault));
    }

    // ------------------------------------------------------------------ lifecycle and bonds

    function testBondsAreLiveMinimumOrImmutableFloorAndReturnedToProposer() public {
        oracle.setMinimumBond(700e6);
        bytes32 id = _propose();
        IOptimisticOracleV3.Assertion memory assertion = oracle.getAssertion(id);
        assertEq(assertion.bond, 700e6);
        assertEq(oracle.defaultIdentifier(), bytes32("ASSERT_TRUTH"));
        assertEq(controller.ASSERTION_IDENTIFIER(), bytes32("ASSERT_TRUTH2"));
        assertEq(assertion.identifier, bytes32("ASSERT_TRUTH2"));
        assertEq(assertion.expirationTime - assertion.assertionTime, 72 hours);
        assertEq(assertion.asserter, address(this));
        assertEq(assertion.callbackRecipient, address(0));
        assertEq(assertion.escalationManagerSettings.escalationManager, address(0));
        assertEq(bond.allowance(address(controller), address(oracle)), 0);
        assertEq(bond.balanceOf(address(controller)), 0);
        assertEq(oracle.syncCount(), 1);
        assertEq(controller.proposal(id).observationDigest, DIGEST);
        assertEq(controller.evidenceURIOf(id), EVIDENCE);
        vm.warp(block.timestamp + 72 hours);
        controller.settle(id);
        assertEq(bond.balanceOf(address(this)), 10000e6);
    }

    function testUndisputedPendingBlocksButADisputedOneDoesNot() public {
        bytes32 id = _propose();
        vm.expectRevert(IndexController.ProposalUnavailable.selector);
        _execute();
        assertFalse(controller.canPropose(QUARTER));
        vm.expectRevert(IndexController.ProposalUnavailable.selector);
        _propose();
        vm.expectRevert(bytes("liveness"));
        controller.settle(id);

        vm.prank(address(123));
        oracle.dispute(id);
        assertTrue(controller.canPropose(QUARTER));
        bytes32 replacement = _propose();
        assertEq(controller.latestProposal(QUARTER), replacement);
        assertFalse(controller.canPropose(QUARTER)); // the replacement is undisputed

        vm.warp(block.timestamp + 72 hours);
        vm.expectRevert(bytes("unresolved dispute"));
        controller.settle(id);
        oracle.resolveDispute(id, false);
        assertFalse(controller.settle(id));
        assertEq(controller.acceptedProposal(QUARTER), bytes32(0));
    }

    function testUnsettledUndisputedProposalIsReplaceableAfterGrace() public {
        bytes32 id = _propose();
        uint256 expiry = oracle.getAssertion(id).expirationTime;
        vm.warp(expiry + controller.SETTLEMENT_GRACE());
        assertFalse(controller.canPropose(QUARTER));
        vm.warp(expiry + controller.SETTLEMENT_GRACE() + 1);
        assertTrue(controller.canPropose(QUARTER));
        assertTrue(_propose() != id);
    }

    function testFirstTrueSettlementIsSelectedAndLateTrueResolutionIsHarmless() public {
        bytes32 first = _propose();
        oracle.dispute(first);
        _shift();
        bytes32 second = _propose();
        vm.warp(1791216000);
        _refresh();
        assertTrue(controller.settle(second));
        assertEq(controller.acceptedProposal(QUARTER), second);
        assertFalse(controller.canPropose(QUARTER));

        oracle.resolveDispute(first, true);
        assertTrue(controller.settle(first));
        assertEq(controller.acceptedProposal(QUARTER), second);
        assertEq(uint256(controller.proposal(first).status), uint256(IndexController.Status.Accepted));

        _execute(); // executes `second`, the shifted target
        assertEq(uint256(controller.proposal(second).status), uint256(IndexController.Status.Executed));
        assertGt(_held(0), 100e8);
    }

    function testResolvedTrueDisputeCanBeAccepted() public {
        bytes32 id = _propose();
        oracle.dispute(id);
        oracle.resolveDispute(id, true);
        vm.warp(block.timestamp + 72 hours);
        assertTrue(controller.settle(id));
        assertEq(controller.acceptedProposal(QUARTER), id);
    }

    function testMalformedProposalsRejected() public {
        vm.expectRevert(IndexController.InvalidQuarter.selector);
        controller.propose(QUARTER - 1, ratios, EVIDENCE, DIGEST);
        uint256[7] memory bad = ratios;
        bad[0] = 0;
        vm.expectRevert(IndexController.InvalidRatios.selector);
        controller.propose(QUARTER, bad, EVIDENCE, DIGEST);
        bad = ratios;
        bad[0] += 1;
        vm.expectRevert(IndexController.InvalidRatios.selector);
        controller.propose(QUARTER, bad, EVIDENCE, DIGEST);
        vm.expectRevert(IndexController.InvalidDigest.selector);
        controller.propose(QUARTER, ratios, EVIDENCE, bytes32(0));
        string[7] memory invalid = [
            "",
            "ipfs://",
            "https://example.com/evidence",
            "ipfs://has space",
            "ipfs://claim;injection",
            "IPFS://bafy",
            string.concat("ipfs://", _repeat("a", 250))
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(IndexController.InvalidURI.selector);
            controller.propose(QUARTER, ratios, invalid[i], DIGEST);
        }
        assertTrue(controller.propose(QUARTER, ratios, "ar://tx-id_1.2~3:4/5", DIGEST) != bytes32(0));
    }

    function testMethodologyURIValidatedAtConstruction() public {
        vm.expectRevert(IndexController.InvalidURI.selector);
        new IndexController(
            IM7CapVault(address(vault)),
            oracle,
            bond,
            600e6,
            keccak256("m"),
            "https://mutable.example",
            valuation
        );
        assertEq(controller.methodologyURI(), METHODOLOGY);
    }

    function testExactGregorianQuarterBoundariesIncludingLeapAndCentury() public view {
        assertEq(controller.quarterAt(1711929599), 2024 * 4);
        assertEq(controller.quarterAt(1711929600), 2024 * 4 + 1);
        assertEq(controller.quarterAt(4110220799), 2100 * 4);
        assertEq(controller.quarterAt(4110220800), 2100 * 4 + 1);
        assertEq(controller.quarterAt(1798761599), 2026 * 4 + 3);
        assertEq(controller.quarterAt(1798761600), 2027 * 4);
        assertEq(controller.quarterAt(0), 1970 * 4);
    }

    function testAcceptedButUnexecutedOldQuarterDoesNotDeadlockFutureQuarter() public {
        _accept();
        vm.warp(1798761600);
        vm.expectRevert(IndexController.ProposalUnavailable.selector);
        _execute();
        bytes32 id = controller.propose(2027 * 4, ratios, "ipfs://next-evidence", DIGEST);
        assertEq(controller.proposal(id).quarter, 2027 * 4);
    }

    function testPermissionlessExecutionOncePerQuarter() public {
        bytes32 id = _accept();
        vm.prank(address(456));
        _execute();
        assertTrue(controller.executedQuarter(QUARTER));
        assertEq(controller.lastExecutedQuarter(), QUARTER);
        assertEq(uint256(controller.proposal(id).status), uint256(IndexController.Status.Executed));
        vm.expectRevert(IndexController.ProposalUnavailable.selector);
        _execute();
        vm.expectRevert(IndexController.InvalidQuarter.selector);
        _propose();
    }

    // ------------------------------------------------------------------ planner and postconditions

    function testUnchangedTargetExecutesWithoutAnyTrade() public {
        _accept();
        _execute();
        assertEq(vault.calls(), 0);
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testPlannerSellsThenBuysWithOracleMinimums() public {
        _shift();
        _accept();
        _execute();
        assertEq(vault.calls(), 2);
        assertEq(vault.legCount(), 2);
        Swap memory sell = vault.legAt(0);
        assertEq(sell.tokenIn, 1);
        assertEq(sell.tokenOut, 7);
        assertEq(sell.amountIn, 3.5e8);
        assertEq(sell.minAmountOut, 346.5e6); // $350 of stock less 1%
        Swap memory buy = vault.legAt(1);
        assertEq(buy.tokenIn, 7);
        assertEq(buy.tokenOut, 0);
        assertEq(buy.amountIn, 350e6);
        assertEq(buy.minAmountOut, 3.465e8);
        assertEq(_held(0), 103.5e8);
        assertEq(_held(1), 96.5e8);
        assertEq(ControllerToken(assets[7]).balanceOf(address(vault)), 0);
    }

    function testFuzzLossBackstopIsOnePercentOfTradedValue(uint16 lossBps) public {
        lossBps = uint16(bound(lossBps, 0, 300));
        _shift();
        _accept();
        vault.setOutputBps(10_000 - lossBps);
        if (lossBps > 100) vm.expectRevert(IndexController.RebalanceLoss.selector);
        _execute();
        assertEq(controller.executedQuarter(QUARTER), lossBps <= 100);
    }

    function testLossLimitAtomicRollbackAndRetry() public {
        bytes32 id = _accept();
        _shift();
        vm.warp(1798761600 + 16 hours); // Jan 1 2027 is a Friday; a fresh quarter
        bytes32 next = controller.propose(2027 * 4, ratios, EVIDENCE, DIGEST);
        vm.warp(block.timestamp + 72 hours + 3 days); // Monday Jan 4 2027 16:00 UTC
        _refresh();
        assertTrue(controller.settle(next));
        vault.setOutputBps(9_800);
        vm.expectRevert(IndexController.RebalanceLoss.selector);
        _execute();
        assertEq(_held(1), 100e8);
        assertEq(vault.calls(), 0);
        assertFalse(controller.executedQuarter(2027 * 4));
        assertEq(uint256(controller.proposal(next).status), uint256(IndexController.Status.Accepted));
        vault.setOutputBps(9_950);
        _execute();
        assertEq(vault.calls(), 2);
        assertTrue(id != next);
    }

    function testComplianceAndCashPostconditionsRollBack() public {
        _shift();
        _accept();
        uint256[8] memory amounts;
        for (uint256 i; i < 7; ++i) {
            amounts[i] = 100e8;
        }
        amounts[1] = 96.5e8;
        amounts[7] = 350e6; // sold but never bought: value kept, target missed
        vault.setAfter(amounts);
        vm.expectRevert(IndexController.NotCompliant.selector);
        _execute();
        amounts[0] = 103.5e8;
        amounts[7] = 8e6; // on target, but $8 of cash exceeds 1 bp of $70,008
        vault.setAfter(amounts);
        vm.expectRevert(IndexController.ResidualCash.selector);
        _execute();
        assertEq(vault.calls(), 0);
    }

    function testOneConsistentPriceSnapshotIsUsed() public {
        _shift();
        _accept();
        // After the sale of stock 1, its feed collapses 99%. A second oracle read would fail the NAV check.
        vault.setChangeFeed(feeds[1]);
        _execute();
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testPriceMovementsChangeWeightsWithoutTrading() public {
        _accept();
        feeds[0].set(200e8, block.timestamp);
        _execute(); // quantity ratios still match although AAPL's dollar weight doubled
        assertEq(vault.calls(), 0);
    }

    function testUnexpectedShareDilutionFailsAtomically() public {
        _shift();
        _accept();
        vault.setDilute(true);
        vm.expectRevert(IndexController.RebalanceLoss.selector);
        _execute();
        assertEq(vault.totalSupply(), 1_000e18);
    }

    function testBogusRatiosMoveEachConstituentAtMostOneStep() public {
        for (uint256 i = 1; i < 7; ++i) {
            ratios[i] = 1;
        }
        ratios[0] = 1e18 - 6;
        _accept();
        _execute();
        // Stock 0 grows exactly one 5% step; the other six shrink by under 1%.
        assertApproxEqAbs(_held(0), 105e8, 10); // floor rounding in the step and targets
        for (uint256 i = 1; i < 7; ++i) {
            assertLt(100e8 - _held(i), 0.84e8);
            assertGt(_held(i), 99e8);
        }
    }

    function testSeizedStockIsRebuiltByTheMinimumStep() public {
        _accept();
        ControllerToken(assets[3]).burn(address(vault), 100e8); // seized to zero: issuance halts
        _execute();
        // Stock 3 regains the 0.25%-of-NAV minimum step; the six others each sell a quarter token to fund it.
        assertApproxEqAbs(_held(3), 1.5e8, 10);
        for (uint256 i; i < 7; ++i) {
            if (i != 3) assertApproxEqAbs(_held(i), 99.75e8, 10);
        }
    }

    function testFreshnessPauseAndDeadlineBlockRebalance() public {
        _shift();
        _accept();
        registry.setPaused(assets[0], true);
        vm.expectRevert(abi.encodeWithSelector(Valuation.CorporateAction.selector, 0));
        _execute();
        registry.setPaused(assets[0], false);
        feeds[0].set(100e8, block.timestamp - 25 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Valuation.UnavailablePrice.selector, 0));
        _execute();
        for (uint256 i; i < 7; ++i) {
            feeds[i].set(100e8, block.timestamp - 2 hours);
        }
        vm.expectRevert(Valuation.NoFreshMarketSignal.selector);
        _execute();
        vm.expectRevert(IndexController.Expired.selector);
        controller.execute(block.timestamp - 1);
        // M-03: one fresh feed is enough while quiet feeds stay inside their heartbeat.
        feeds[3].set(100e8, block.timestamp);
        _execute();
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testAssertionClaimBindsExactMethodologyEvidenceAndContext() public {
        bytes memory expected = controller.claim(QUARTER, ratios, EVIDENCE, DIGEST);
        _propose();
        assertEq(oracle.lastClaim(), expected);
        string memory text = string(expected);
        assertTrue(_contains(text, "methodologyURI=ipfs://bafymethodology"));
        assertTrue(_contains(text, "evidenceURI=ipfs://bafyevidence"));
        assertTrue(_contains(text, "observationCutoff=2026-09-30T23:59:59Z"));
        assertTrue(_contains(text, vm.toLowercase(vm.toString(DIGEST))));
        assertTrue(_contains(text, "TSLAc token="));
        assertTrue(keccak256(controller.claim(QUARTER + 1, ratios, EVIDENCE, DIGEST)) != keccak256(expected));
        assertTrue(
            keccak256(controller.claim(QUARTER, ratios, EVIDENCE, bytes32(uint256(1)))) != keccak256(expected)
        );
        assertTrue(
            _contains(string(controller.claim(2027 * 4, ratios, EVIDENCE, DIGEST)), "2026-12-31T23:59:59Z")
        );
    }

    function _repeat(string memory unit, uint256 count) private pure returns (string memory out) {
        for (uint256 i; i < count; ++i) {
            out = string.concat(out, unit);
        }
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool matched = true;
            for (uint256 j; j < n.length && matched; ++j) {
                matched = h[i + j] == n[j];
            }
            if (matched) return true;
        }
        return false;
    }
}
