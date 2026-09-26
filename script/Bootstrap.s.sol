// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {M7CapVault} from "../src/M7CapVault.sol";

/// @notice Deposit an already acquired, reviewed seed basket in one atomic bootstrap call.
contract Bootstrap is Script {
    function run() external {
        M7CapVault vault = M7CapVault(vm.envAddress("VAULT"));
        address deployer = vm.envAddress("DEPLOYER");
        require(vault.bootstrapper() == deployer && vault.totalSupply() == 0, "invalid bootstrap state");
        string memory config = vm.readFile("config/seed.json");
        require(vm.parseJsonAddress(config, ".vault") == address(vault), "wrong vault");
        require(vm.parseJsonUint(config, ".chain_id") == block.chainid, "wrong chain");
        address receiver = vm.parseJsonAddress(config, ".receiver");
        uint256[] memory input = vm.parseJsonUintArray(config, ".raw_amounts");
        require(input.length == 8 && input[7] == 0, "seven stocks, zero strategic cash");
        uint256[8] memory amounts;
        for (uint256 i; i < 7; ++i) {
            require(input[i] != 0, "missing stock");
            amounts[i] = input[i];
            require(vault.assets(i).balanceOf(deployer) >= amounts[i], "seed not funded");
        }
        vm.startBroadcast(deployer);
        for (uint256 i; i < 7; ++i) {
            require(vault.assets(i).approve(address(vault), amounts[i]), "approval failed");
        }
        vault.bootstrap(amounts, receiver);
        vm.stopBroadcast();
        console2.log("Bootstrapped M7CAP", address(vault));
    }
}
