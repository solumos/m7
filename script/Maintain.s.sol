// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexController} from "../src/IndexController.sol";
import {Swap} from "../src/Types.sol";

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
        string[] memory inputs = vm.parseJsonStringArray(snapshot, ".quantity_ratios");
        require(inputs.length == 7, "invalid ratios");
        uint256[7] memory ratios;
        for (uint256 i; i < 7; ++i) {
            ratios[i] = vm.parseUint(inputs[i]);
        }
        bytes memory evidence = bytes(vm.envString("EVIDENCE_URI"));
        vm.startBroadcast(proposer);
        controller.oracle()
            .syncUmaParams(controller.ASSERTION_IDENTIFIER(), address(controller.bondCurrency()));
        uint256 bond = Math.max(
            controller.bondFloor(), controller.oracle().getMinimumBond(address(controller.bondCurrency()))
        );
        require(controller.bondCurrency().approve(address(controller), bond), "bond approval failed");
        bytes32 assertionId = controller.propose(uint32(quarter), ratios, evidence);
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

/// @notice Execute a prequoted typed swap plan. Every constraint is checked by the contracts.
contract Execute is Script {
    function run() external {
        IndexController controller = IndexController(vm.envAddress("CONTROLLER"));
        string memory plan = vm.readFile("config/rebalance.json");
        require(vm.parseJsonAddress(plan, ".controller") == address(controller), "wrong controller");
        require(vm.parseJsonUint(plan, ".chain_id") == block.chainid, "wrong chain");
        require(vm.parseJsonUint(plan, ".quarter_id") == controller.currentQuarter(), "wrong quarter");
        uint256 count = vm.parseJsonUint(plan, ".swap_count");
        require(count <= 14, "too many swaps");
        Swap[] memory swaps = new Swap[](count);
        for (uint256 i; i < count; ++i) {
            string memory key = string.concat(".swaps[", vm.toString(i), "]");
            uint256 tokenIn = vm.parseJsonUint(plan, string.concat(key, ".token_in"));
            uint256 tokenOut = vm.parseJsonUint(plan, string.concat(key, ".token_out"));
            uint256 spacing = vm.parseJsonUint(plan, string.concat(key, ".tick_spacing"));
            require(
                tokenIn <= 7 && tokenOut <= 7 && spacing <= uint256(uint24(type(int24).max)), "invalid route"
            );
            swaps[i] = Swap({
                tokenIn: uint8(tokenIn),
                tokenOut: uint8(tokenOut),
                tickSpacing: int24(int256(spacing)),
                amountIn: vm.parseJsonUint(plan, string.concat(key, ".amount_in")),
                minAmountOut: vm.parseJsonUint(plan, string.concat(key, ".min_amount_out"))
            });
        }
        vm.startBroadcast(vm.envAddress("EXECUTOR"));
        controller.execute(swaps, vm.parseJsonUint(plan, ".deadline"));
        vm.stopBroadcast();
    }
}
