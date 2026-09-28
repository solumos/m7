// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation} from "../src/Valuation.sol";
import {ISlipstreamRouter} from "../src/interfaces/ISlipstreamRouter.sol";

/// @notice Buy the seed basket's shortfall for Bootstrap.s.sol through the vault's own pinned pools.
/// @dev Each purchase is exact-output and pays at most its oracle value plus `MAX_PREMIUM_BPS`: a pool priced above
///      that reverts the swap instead of overpaying. Approvals are exact and reset to zero.
contract AcquireSeed is Script {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PREMIUM_BPS = 100;

    function run() external {
        M7Vault vault = M7Vault(payable(vm.envAddress("VAULT")));
        address deployer = vm.envAddress("DEPLOYER");
        require(vault.bootstrapper() == deployer && vault.totalSupply() == 0, "invalid bootstrap state");
        string memory seed = vm.readFile(vm.envOr("SEED_FILE", string("config/seed.json")));
        require(vm.parseJsonAddress(seed, ".vault") == address(vault), "wrong vault");
        require(vm.parseJsonUint(seed, ".chain_id") == block.chainid, "wrong chain");
        uint256[] memory amounts = vm.parseJsonUintArray(seed, ".raw_amounts");
        require(amounts.length == 8 && amounts[7] == 0, "seven stocks, zero strategic cash");
        uint256 deadline = vm.envOr("DEADLINE", uint256(0));
        if (deadline == 0) deadline = block.timestamp + 15 minutes;

        (uint256[7] memory need, uint256[7] memory maxIn, uint256 budget) = _plan(vault, deployer, amounts);
        require(vault.assets(7).balanceOf(deployer) >= budget, "fund the deployer with the USDC budget first");
        console2.log("USDC budget (6 decimals)", budget);

        vm.startBroadcast(deployer);
        for (uint256 i; i < 7; ++i) {
            if (need[i] != 0) _buy(vault, i, need[i], maxIn[i], deadline, deployer);
        }
        vm.stopBroadcast();
        for (uint256 i; i < 7; ++i) {
            require(vault.assets(i).balanceOf(deployer) >= amounts[i], "seed not funded");
        }
    }

    /// @dev Each stock's shortfall and its USDC ceiling: the oracle value plus the premium, rounded up.
    function _plan(M7Vault vault, address deployer, uint256[] memory amounts)
        private
        view
        returns (uint256[7] memory need, uint256[7] memory maxIn, uint256 budget)
    {
        Valuation valuation = IndexController(vault.controller()).valuation();
        // Rehearsals on a quiet fork may relax this; a real acquisition runs in market hours with fresh feeds.
        uint256 maxAge = vm.envOr("MAX_FEED_AGE", valuation.maxAge());
        uint256 usdcPrice = _price(valuation, 7, maxAge);
        for (uint256 i; i < 7; ++i) {
            uint256 held = vault.assets(i).balanceOf(deployer);
            if (held >= amounts[i]) continue;
            need[i] = amounts[i] - held;
            maxIn[i] = Math.mulDiv(
                need[i] * _price(valuation, i, maxAge),
                valuation.tokenUnits(7) * (BPS + MAX_PREMIUM_BPS),
                valuation.tokenUnits(i) * usdcPrice * BPS,
                Math.Rounding.Ceil
            );
            budget += maxIn[i];
        }
    }

    function _buy(
        M7Vault vault,
        uint256 index,
        uint256 amountOut,
        uint256 maxIn,
        uint256 deadline,
        address to
    ) private {
        IERC20 usdc = vault.assets(7);
        ISlipstreamRouter router = vault.router();
        require(usdc.approve(address(router), maxIn), "approval failed");
        uint256 spent = router.exactOutputSingle(
            ISlipstreamRouter.ExactOutputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(vault.assets(index)),
                tickSpacing: vault.tickSpacing(index),
                recipient: to,
                deadline: deadline,
                amountOut: amountOut,
                amountInMaximum: maxIn,
                sqrtPriceLimitX96: 0
            })
        );
        require(usdc.approve(address(router), 0), "approval reset failed");
        console2.log("Stock index, raw bought, USDC spent", index, amountOut, spent);
    }

    /// @dev 1e18-scaled USD price of one whole token from the valuation's own feed, refusing stale answers.
    function _price(Valuation valuation, uint256 index, uint256 maxAge) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = valuation.feeds(index).latestRoundData();
        require(
            answer > 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge,
            "stale or invalid feed"
        );
        return Math.mulDiv(uint256(answer), 1e18, valuation.feedUnits(index));
    }
}
