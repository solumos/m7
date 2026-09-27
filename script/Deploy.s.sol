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
import {IPolicyRegistry} from "../src/interfaces/IB20Policy.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {RawCid} from "./RawCid.sol";

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
        IOptimisticOracleV3 oracle;
        IAggregatorV3 sequencer;
        ICoinbaseOracleRegistry issuerRegistry;
        uint256 maxAge;
    }

    function run() external {
        string memory config = vm.readFile("config/base.json");
        require(block.chainid == vm.parseJsonUint(config, ".chain_id"), "wrong chain");
        address deployer = vm.envAddress("DEPLOYER");
        require(deployer != address(0), "missing deployer");
        string memory methodologyURI = vm.envString("METHODOLOGY_URI");
        bytes memory methodology = bytes(vm.readFile("docs/METHODOLOGY.md"));
        // The URI is immutable and printed in every claim, which is false if the document is not at that location.
        require(
            keccak256(bytes(methodologyURI)) == keccak256(bytes(RawCid.uri(methodology))),
            "METHODOLOGY_URI must be the raw CIDv1 of docs/METHODOLOGY.md (python3 scripts/ipfs_cid.py)"
        );
        Config memory c = _read(config);
        bytes32 methodologyHash = keccak256(methodology);
        address predictedVault = vm.computeCreateAddress(deployer, uint256(vm.getNonce(deployer)) + 2);

        vm.startBroadcast(deployer);
        Valuation valuation =
            new Valuation(c.assetAddresses, c.feeds, c.sequencer, c.issuerRegistry, c.maxAge);
        IndexController controller = new IndexController(
            IM7CapVault(predictedVault),
            c.oracle,
            c.assets[7],
            vm.envOr("BOND_FLOOR_USDC", uint256(1_000e6)),
            methodologyHash,
            methodologyURI,
            valuation
        );
        M7CapVault vault = new M7CapVault(
            c.assets, c.spacings, address(controller), c.router, c.factory, c.policyRegistry, deployer
        );
        require(address(vault) == predictedVault, "CREATE nonce mismatch");
        USDCGateway gateway = new USDCGateway(IM7CapVault(address(vault)));
        vm.stopBroadcast();

        require(
            address(controller.vault()) == address(vault) && vault.controller() == address(controller), "link"
        );
        require(address(gateway.vault()) == address(vault), "gateway");
        console2.log("Vault", address(vault));
        console2.log("Gateway", address(gateway));
        console2.log("Controller", address(controller));
        console2.log("Valuation", address(valuation));
        console2.log("Methodology keccak256:");
        console2.logBytes32(methodologyHash);
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
        c.oracle = IOptimisticOracleV3(vm.parseJsonAddress(config, ".uma_oo_v3"));
        c.sequencer = IAggregatorV3(vm.parseJsonAddress(config, ".sequencer_feed"));
        c.issuerRegistry = ICoinbaseOracleRegistry(vm.parseJsonAddress(config, ".registry"));
        c.maxAge = vm.parseJsonUint(config, ".risk_checks.max_stock_feed_age_seconds");
    }
}
