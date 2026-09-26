// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3, ICoinbaseOracleRegistry} from "../src/Valuation.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";

/// @notice Reproducible deployment simulation. Nothing is broadcast unless explicitly requested by Forge.
/// @dev The controller/vault pair uses CREATE address prediction, not a mutable initialization setter.
contract Deploy is Script {
    function run() external {
        string memory config = vm.readFile("config/base.json");
        require(block.chainid == vm.parseJsonUint(config, ".chain_id"), "wrong chain");
        address deployer = vm.envAddress("DEPLOYER");
        require(deployer != address(0), "missing deployer");
        IERC20[8] memory assets;
        address[8] memory assetAddresses;
        IAggregatorV3[8] memory feeds;
        for (uint256 i; i < 7; ++i) {
            string memory key = string.concat(".stocks[", vm.toString(i), "]");
            assetAddresses[i] = vm.parseJsonAddress(config, string.concat(key, ".address"));
            assets[i] = IERC20(assetAddresses[i]);
            feeds[i] = IAggregatorV3(vm.parseJsonAddress(config, string.concat(key, ".feed")));
        }
        assetAddresses[7] = vm.parseJsonAddress(config, ".usdc.address");
        assets[7] = IERC20(assetAddresses[7]);
        feeds[7] = IAggregatorV3(vm.parseJsonAddress(config, ".usdc.feed"));
        ISlipstreamRouter router = ISlipstreamRouter(vm.parseJsonAddress(config, ".venue.router"));
        ISlipstreamFactory factory = ISlipstreamFactory(vm.parseJsonAddress(config, ".venue.factory"));
        bytes32 methodologyHash = keccak256(bytes(vm.readFile("docs/METHODOLOGY.md")));
        address predictedVault = vm.computeCreateAddress(deployer, uint256(vm.getNonce(deployer)) + 2);

        vm.startBroadcast(deployer);
        Valuation valuation = new Valuation(
            assetAddresses,
            feeds,
            IAggregatorV3(vm.parseJsonAddress(config, ".sequencer_feed")),
            ICoinbaseOracleRegistry(vm.parseJsonAddress(config, ".registry")),
            vm.parseJsonUint(config, ".risk_checks.max_stock_feed_age_seconds")
        );
        IndexController controller = new IndexController(
            IM7CapVault(predictedVault),
            IOptimisticOracleV3(vm.parseJsonAddress(config, ".uma_oo_v3")),
            assets[7],
            vm.envOr("BOND_FLOOR_USDC", uint256(1_000e6)),
            methodologyHash,
            valuation
        );
        M7CapVault vault = new M7CapVault(assets, address(controller), router, factory, deployer);
        require(address(vault) == predictedVault, "CREATE nonce mismatch");
        USDCGateway gateway = new USDCGateway(IM7CapVault(address(vault)), router, factory);
        vm.stopBroadcast();

        console2.log("Vault", address(vault));
        console2.log("Gateway", address(gateway));
        console2.log("Controller", address(controller));
        console2.log("Valuation", address(valuation));
        console2.log("Methodology keccak256:");
        console2.logBytes32(methodologyHash);
        console2.log("Unseeded: public minting remains disabled until funded bootstrap.");
    }
}
