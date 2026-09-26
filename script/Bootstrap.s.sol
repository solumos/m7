// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation} from "../src/Valuation.sol";

/// @notice Deposit an already acquired, reviewed seed basket in one atomic bootstrap call.
/// @dev Verifies the deployed contracts' on-chain linkage first: nothing is funded against a mis-bound deployment.
contract Bootstrap is Script {
    function run() external {
        M7CapVault vault = M7CapVault(payable(vm.envAddress("VAULT")));
        address deployer = vm.envAddress("DEPLOYER");
        require(vault.bootstrapper() == deployer && vault.totalSupply() == 0, "invalid bootstrap state");
        _verifyLinkage(vault);
        string memory config = vm.readFile(vm.envOr("SEED_FILE", string("config/seed.json")));
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

    function _verifyLinkage(M7CapVault vault) private view {
        IndexController controller = IndexController(vault.controller());
        require(address(controller).code.length > 0, "controller missing");
        require(address(controller.vault()) == address(vault), "controller not bound to vault");
        Valuation valuation = controller.valuation();
        require(address(valuation).code.length > 0, "valuation missing");
        for (uint256 i; i < 8; ++i) {
            require(address(vault.assets(i)) == valuation.assets(i), "valuation asset mismatch");
        }
        for (uint256 i; i < 7; ++i) {
            require(
                vault.factory()
                        .getPool(address(vault.assets(i)), address(vault.assets(7)), vault.tickSpacing(i))
                    != address(0),
                "pinned pool missing"
            );
        }
        address gateway = vm.envOr("GATEWAY", address(0));
        if (gateway != address(0)) {
            require(
                address(USDCGateway(payable(gateway)).vault()) == address(vault), "gateway not bound to vault"
            );
        }
    }
}
