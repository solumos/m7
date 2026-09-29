// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {M7Lens} from "../src/M7Lens.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3, ICoinbaseOracleRegistry} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {IPolicyRegistry} from "../src/interfaces/IB20Policy.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";

/// @notice Reproducible deployment simulation. Nothing is broadcast unless explicitly requested by Forge.
/// @dev The controller/vault pair uses CREATE address prediction, not a mutable initialization setter. The vault's
///      constructor also refuses a controller that is not bound to it, so nonce drift fails the deployment.
contract Deploy is Script {
    struct Config {
        IERC20[8] assets;
        address[8] assetAddresses;
        IAggregatorV3[8] feeds;
        int24[7] spacings;
        ISlipstreamRouter router;
        ISlipstreamFactory factory;
        IPolicyRegistry policyRegistry;
        IAggregatorV3 sequencer;
        ICoinbaseOracleRegistry issuerRegistry;
        uint256 maxAge;
    }

    function run() external {
        string memory config = vm.readFile("config/base.json");
        require(block.chainid == vm.parseJsonUint(config, ".chain_id"), "wrong chain");
        address deployer = vm.envAddress("DEPLOYER");
        require(deployer != address(0), "missing deployer");
        Config memory c = _read(config);
        address predictedVault = vm.computeCreateAddress(deployer, uint256(vm.getNonce(deployer)) + 2);

        vm.startBroadcast(deployer);
        Valuation valuation =
            new Valuation(c.assetAddresses, c.feeds, c.sequencer, c.issuerRegistry, c.maxAge);
        IndexController controller = new IndexController(IM7Vault(predictedVault), valuation);
        M7Vault vault = new M7Vault(
            c.assets, c.spacings, address(controller), c.router, c.factory, c.policyRegistry, deployer
        );
        require(address(vault) == predictedVault, "CREATE nonce mismatch");
        USDCGateway gateway = new USDCGateway(IM7Vault(address(vault)));
        // Read-only price per share; replaceable at any time without touching the other contracts.
        M7Lens lens = new M7Lens(controller);
        vm.stopBroadcast();

        require(
            address(controller.vault()) == address(vault) && vault.controller() == address(controller), "link"
        );
        require(address(gateway.vault()) == address(vault), "gateway");
        require(address(lens.vault()) == address(vault) && lens.valuation() == valuation, "lens");
        console2.log("Vault", address(vault));
        console2.log("Gateway", address(gateway));
        console2.log("Lens", address(lens));
        console2.log("Controller", address(controller));
        console2.log("Valuation", address(valuation));
        console2.log("Unseeded: public minting remains disabled until funded bootstrap.");
    }

    function _read(string memory config) private pure returns (Config memory c) {
        for (uint256 i; i < 7; ++i) {
            string memory key = string.concat(".stocks[", vm.toString(i), "]");
            c.assetAddresses[i] = vm.parseJsonAddress(config, string.concat(key, ".address"));
            c.assets[i] = IERC20(c.assetAddresses[i]);
            c.feeds[i] = IAggregatorV3(vm.parseJsonAddress(config, string.concat(key, ".feed")));
            uint256 spacing = vm.parseJsonUint(config, string.concat(key, ".tick_spacing"));
            require(spacing != 0 && spacing <= uint256(uint24(type(int24).max)), "invalid tick spacing");
            c.spacings[i] = int24(int256(spacing));
        }
        c.assetAddresses[7] = vm.parseJsonAddress(config, ".usdc.address");
        c.assets[7] = IERC20(c.assetAddresses[7]);
        c.feeds[7] = IAggregatorV3(vm.parseJsonAddress(config, ".usdc.feed"));
        c.router = ISlipstreamRouter(vm.parseJsonAddress(config, ".venue.router"));
        c.factory = ISlipstreamFactory(vm.parseJsonAddress(config, ".venue.factory"));
        c.policyRegistry = IPolicyRegistry(vm.parseJsonAddress(config, ".policy_registry"));
        c.sequencer = IAggregatorV3(vm.parseJsonAddress(config, ".sequencer_feed"));
        c.issuerRegistry = ICoinbaseOracleRegistry(vm.parseJsonAddress(config, ".registry"));
        c.maxAge = vm.parseJsonUint(config, ".risk_checks.max_stock_feed_age_seconds");
    }
}
