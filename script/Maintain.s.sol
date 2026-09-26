// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexController} from "../src/IndexController.sol";

/// @notice Submit a reviewed snapshot. The proposer supplies its own refundable oracle bond.
contract Propose is Script {
    function run() external {
        IndexController controller = IndexController(vm.envAddress("CONTROLLER"));
        address proposer = vm.envAddress("PROPOSER");
        require(
            controller.methodologyHash() == keccak256(bytes(vm.readFile("docs/METHODOLOGY.md"))),
            "methodology mismatch"
        );
        string memory snapshot = vm.readFile("config/snapshot.json");
        uint256 quarter = vm.parseJsonUint(snapshot, ".quarter_id");
        require(quarter == controller.currentQuarter(), "wrong quarter");
        require(controller.canPropose(uint32(quarter)), "quarter has a live proposal");
        string[] memory inputs = vm.parseJsonStringArray(snapshot, ".quantity_ratios");
        require(inputs.length == 7, "invalid ratios");
        uint256[7] memory ratios;
        for (uint256 i; i < 7; ++i) {
            ratios[i] = vm.parseUint(inputs[i]);
        }
        bytes32 digest = vm.parseJsonBytes32(snapshot, ".observation_sha256");
        string memory evidence = vm.envString("EVIDENCE_URI");
        vm.startBroadcast(proposer);
        controller.oracle()
            .syncUmaParams(controller.ASSERTION_IDENTIFIER(), address(controller.bondCurrency()));
        uint256 bond = Math.max(
            controller.bondFloor(), controller.oracle().getMinimumBond(address(controller.bondCurrency()))
        );
        require(controller.bondCurrency().approve(address(controller), bond), "bond approval failed");
        bytes32 assertionId = controller.propose(uint32(quarter), ratios, evidence, digest);
        vm.stopBroadcast();
        console2.log("Assertion:");
        console2.logBytes32(assertionId);
    }
}

contract Settle is Script {
    function run() external {
        IndexController controller = IndexController(vm.envAddress("CONTROLLER"));
        vm.startBroadcast(vm.envAddress("EXECUTOR"));
        bool accepted = controller.settle(vm.envBytes32("ASSERTION_ID"));
        vm.stopBroadcast();
        console2.log("Assertion accepted", accepted);
    }
}

/// @notice Execute the current quarter's selected proposal. The controller plans every trade on-chain from
///         current backing and one oracle snapshot; the executor only chooses when to call and the deadline.
contract Execute is Script {
    function run() external {
        IndexController controller = IndexController(vm.envAddress("CONTROLLER"));
        uint256 deadline = vm.envOr("DEADLINE", uint256(0));
        if (deadline == 0) deadline = block.timestamp + 15 minutes;
        vm.startBroadcast(vm.envAddress("EXECUTOR"));
        controller.execute(deadline);
        vm.stopBroadcast();
    }
}
