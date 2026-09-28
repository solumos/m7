// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISlipstreamRouter} from "../src/interfaces/ISlipstreamRouter.sol";

interface IRouterPayments {
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;
    function refundETH() external payable;
}

/// @dev Calls the router the way M7Vault.rebalance and USDCGateway do: from a contract without receive().
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

/// @dev The fix for N-01: like M7Vault and USDCGateway, accepts the router's ETH refund and nothing else.
contract RouterGatedSwapper is NoReceiveSwapper {
    address private immutable _router;

    constructor(ISlipstreamRouter router_) NoReceiveSwapper(router_) {
        _router = address(router_);
    }

    receive() external payable {
        require(msg.sender == _router, "router only");
    }
}

contract Audit2ForkTest is Test {
    ISlipstreamRouter constant ROUTER = ISlipstreamRouter(0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // Cleanup refunds arrive here; only the deliberately vulnerable victim lacks receive().
    receive() external payable {}

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
}
