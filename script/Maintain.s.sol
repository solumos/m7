// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IndexController} from "../src/IndexController.sol";

/// @notice Run this quarter's reset to equal weights. Anyone may; the controller plans every trade on chain from
///         current backing and one oracle snapshot, so the caller only chooses when and where any reward goes.
contract Rebalance is Script {
    function run() external {
        IndexController controller = IndexController(vm.envAddress("CONTROLLER"));
        address caller = vm.envAddress("EXECUTOR");
        require(controller.rebalanceDue(), "this quarter's reset already ran");
        uint256 deadline = vm.envOr("DEADLINE", uint256(0));
        if (deadline == 0) deadline = block.timestamp + 15 minutes;
        address rewardTo = vm.envOr("REWARD_TO", caller);
        vm.startBroadcast(caller);
        controller.rebalance(deadline, rewardTo);
        vm.stopBroadcast();
        console2.log("Reset quarter", controller.lastExecutedQuarter());
    }
}
