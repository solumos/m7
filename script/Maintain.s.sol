// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IndexController} from "../src/IndexController.sol";

/// @notice Run one tranche of this quarter's reset to equal weights. Anyone may; the controller plans every trade on
///         chain from current backing and one oracle snapshot, so the caller only chooses when and where any reward
///         goes. Repeat, at least 30 minutes apart, until the quarter's reset completes.
contract Rebalance is Script {
    function run() external {
        IndexController controller = IndexController(vm.envAddress("CONTROLLER"));
        address caller = vm.envAddress("EXECUTOR");
        uint32 quarter = controller.currentQuarter();
        require(!controller.executedQuarter(quarter), "this quarter's reset is complete");
        require(block.timestamp >= controller.nextTrancheAt(), "too soon: see nextTrancheAt()");
        uint256 deadline = vm.envOr("DEADLINE", uint256(0));
        if (deadline == 0) deadline = block.timestamp + 15 minutes;
        address rewardTo = vm.envOr("REWARD_TO", caller);
        vm.startBroadcast(caller);
        controller.rebalance(deadline, rewardTo);
        vm.stopBroadcast();
        if (controller.executedQuarter(quarter)) {
            console2.log("Reset complete for quarter", quarter);
        } else {
            console2.log("Tranche done; run again at or after (unix seconds)", controller.nextTrancheAt());
        }
    }
}
