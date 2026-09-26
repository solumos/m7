// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    IAggregatorV3[8] feeds;
    ControllerFeed sequencer;
    ControllerRegistry registry;
    uint256[7] ratios;
    uint32 constant QUARTER = 2026 * 4 + 3;

    function setUp() public {
        vm.warp(1790870400); // Thursday Oct 1 2026 16:00 UTC.
        for (uint256 i; i < 8; ++i) {
            assets[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(100e8));
            if (i < 7) ratios[i] = uint256(1e18) / 7;
        }
        ratios[6] += 1e18 % 7;
        sequencer = new ControllerFeed(0, 0);
        registry = new ControllerRegistry();
        valuation = new Valuation(assets, feeds, sequencer, registry, 1 hours);
        vault = new ControllerVault(assets);
        for (uint256 i; i < 7; ++i) {
            ControllerToken(assets[i]).mint(address(vault), 100e8);
        }
        oracle = new ControllerOracle();
        bond = new ControllerToken(6);
        controller = new IndexController(
            IM7CapVault(address(vault)), oracle, bond, 600e6, keccak256("methodology"), valuation
        );
        bond.mint(address(this), 10000e6);
        bond.approve(address(controller), type(uint256).max);
    }

    function _propose() private returns (bytes32) {
        return controller.propose(QUARTER, ratios, bytes("ipfs://evidence"));
    }

    function _accept() private returns (bytes32 id) {
        id = _propose();
        vm.warp(1791216000); // Monday Oct 5, 96h later.
        _refresh();
        assertTrue(controller.settle(id));
    }

    function _refresh() private {
        for (uint256 i; i < 8; ++i) {
            ControllerFeed(address(feeds[i])).set(i == 7 ? int256(1e8) : int256(100e8), block.timestamp);
        }
        sequencer.set(0, block.timestamp);
    }

    function _balances(uint256 stockAmount) private pure returns (uint256[8] memory amounts) {
        for (uint256 i; i < 7; ++i) {
            amounts[i] = stockAmount;
        }
    }

    function _execute() private {
        controller.execute(new Swap[](0), block.timestamp);
    }

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
        vm.warp(block.timestamp + 72 hours);
        controller.settle(id);
        assertEq(bond.balanceOf(address(this)), 10000e6);
    }

    function testPendingAndDisputedAssertionsCannotExecuteAndFalseCanRetry() public {
        bytes32 id = _propose();
        vm.expectRevert(IndexController.ProposalUnavailable.selector);
        _execute();
        vm.expectRevert(bytes("liveness"));
        controller.settle(id);
        vm.prank(address(123));
        oracle.dispute(id);
        vm.warp(block.timestamp + 72 hours);
        vm.expectRevert(bytes("unresolved dispute"));
        controller.settle(id);
        oracle.resolveDispute(id, false);
        assertFalse(controller.settle(id));
        bytes32 retry = _propose();
        assertTrue(retry != id);
    }

    function testResolvedTrueDisputeCanBeAccepted() public {
        bytes32 id = _propose();
        oracle.dispute(id);
        oracle.resolveDispute(id, true);
        vm.warp(block.timestamp + 72 hours);
        assertTrue(controller.settle(id));
    }

    function testDuplicateQuarterAndMalformedInputsRejected() public {
        vm.expectRevert(IndexController.InvalidQuarter.selector);
        controller.propose(QUARTER - 1, ratios, "evidence");
        uint256[7] memory bad = ratios;
        bad[0] = 0;
        vm.expectRevert(IndexController.InvalidRatios.selector);
        controller.propose(QUARTER, bad, "evidence");
        vm.expectRevert(IndexController.InvalidEvidence.selector);
        controller.propose(QUARTER, ratios, "");
        _propose();
        vm.expectRevert(IndexController.ProposalUnavailable.selector);
        _propose();
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
        bytes32 id = controller.propose(2027 * 4, ratios, "ipfs://next-evidence");
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

    function testLossLimitAtomicRollbackAndRetry() public {
        bytes32 id = _accept();
        vault.setAfter(_balances(99e8));
        vm.expectRevert(IndexController.RebalanceLoss.selector);
        _execute();
        assertEq(ControllerToken(assets[0]).balanceOf(address(vault)), 100e8);
        assertEq(vault.calls(), 0);
        assertFalse(controller.executedQuarter(QUARTER));
        assertEq(uint256(controller.proposal(id).status), uint256(IndexController.Status.Accepted));
        vault.setAfter(_balances(995e7)); // Exactly 50 bps loss succeeds.
        _execute();
        assertEq(vault.calls(), 1);
    }

    function testFuzzLossLimitIs50BasisPointsForTheWholeBatch(uint16 lossBps) public {
        lossBps = uint16(bound(lossBps, 0, 100));
        _accept();
        vault.setAfter(_balances(100e8 * (10000 - uint256(lossBps)) / 10000));
        if (lossBps > 50) vm.expectRevert(IndexController.RebalanceLoss.selector);
        _execute();
        assertEq(controller.executedQuarter(QUARTER), lossBps <= 50);
    }

    function testWeightDeviationAndCashLimitRollback() public {
        _accept();
        uint256[8] memory amounts = _balances(100e8);
        amounts[0] -= 3e8;
        amounts[1] += 3e8;
        vault.setAfter(amounts);
        vm.expectRevert(abi.encodeWithSelector(IndexController.TargetDeviation.selector, 0));
        _execute();
        amounts = _balances(100e8);
        amounts[7] = 8e6; // $8 of $70,008 exceeds 1bp.
        vault.setAfter(amounts);
        vm.expectRevert(IndexController.ResidualCash.selector);
        _execute();
        assertEq(vault.calls(), 0);
    }

    function testOneConsistentPriceSnapshotIsUsed() public {
        _accept();
        vault.setChangeFeed(ControllerFeed(address(feeds[0])));
        _execute(); // A second oracle read would see AAPL fall 99% and fail NAV.
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testPriceMovementsChangeTargetWeightsWithoutTrading() public {
        _accept();
        ControllerFeed(address(feeds[0])).set(200e8, block.timestamp);
        _execute(); // Quantity ratios still match although AAPL's dollar weight doubled.
    }

    function testUnexpectedShareDilutionFailsAtomically() public {
        _accept();
        vault.setDilute(true);
        vm.expectRevert(IndexController.RebalanceLoss.selector);
        _execute();
        assertEq(vault.totalSupply(), 100e18);
    }

    function testCannotEmptyEvenATinyConstituentWithinWeightTolerance() public {
        // An accepted target can never authorize dropping a constituent entirely.
        ratios[0] = 1;
        for (uint256 i = 1; i < 7; ++i) {
            ratios[i] = (uint256(1e18) - 1) / 6;
        }
        ratios[6] += (uint256(1e18) - 1) % 6;
        _accept();
        uint256[8] memory amounts;
        for (uint256 i = 1; i < 7; ++i) {
            amounts[i] = uint256(700e8) / 6;
        }
        amounts[6] += uint256(700e8) % 6;
        vault.setAfter(amounts);
        vm.expectRevert(abi.encodeWithSelector(IndexController.TargetDeviation.selector, 0));
        _execute();
        assertEq(ControllerToken(assets[0]).balanceOf(address(vault)), 100e8);
    }

    function testFreshnessPauseAndDeadlineBlockRebalance() public {
        _accept();
        registry.setPaused(assets[0], true);
        vm.expectRevert(abi.encodeWithSelector(Valuation.CorporateAction.selector, 0));
        _execute();
        registry.setPaused(assets[0], false);
        ControllerFeed(address(feeds[0])).set(100e8, block.timestamp - 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Valuation.UnavailablePrice.selector, 0));
        _execute();
        _refresh();
        vm.expectRevert(bytes("deadline"));
        controller.execute(new Swap[](0), block.timestamp - 1);
    }

    function testAssertionClaimBindsExactMethodologyAndContractContext() public {
        bytes memory expected = controller.claim(QUARTER, ratios, "ipfs://evidence");
        _propose();
        assertEq(oracle.lastClaim(), expected);
        assertTrue(expected.length > 1000);
        bytes memory changed = controller.claim(QUARTER + 1, ratios, "ipfs://evidence");
        assertTrue(keccak256(changed) != keccak256(expected));
    }
}
