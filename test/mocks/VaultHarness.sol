// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7CapVault} from "../../src/M7CapVault.sol";
import {IM7CapVault} from "../../src/interfaces/IM7CapVault.sol";
import {IControllerBinding, IPolicyRegistry} from "../../src/interfaces/IB20Policy.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../../src/interfaces/ISlipstreamRouter.sol";
import {Swap} from "../../src/Types.sol";

/// @dev Stands in for a controller bound to a predicted vault address and forwards rebalances in unit tests.
contract ControllerStub is IControllerBinding {
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function rebalance(Swap[] calldata swaps, uint256 deadline) external {
        IM7CapVault(vault).rebalance(swaps, deadline);
    }
}

/// @dev Deploys a vault bound to a `ControllerStub`, as the deployment script binds the real controller.
abstract contract VaultHarness is Test {
    function _spacings(int24 spacing) internal pure returns (int24[7] memory spacings) {
        for (uint256 i; i < 7; ++i) {
            spacings[i] = spacing;
        }
    }

    function _deployVault(
        IERC20[8] memory assets,
        int24[7] memory spacings,
        ISlipstreamRouter router,
        ISlipstreamFactory factory,
        IPolicyRegistry registry
    ) internal returns (M7CapVault vault, ControllerStub stub) {
        address predicted = vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        stub = new ControllerStub(predicted);
        vault = new M7CapVault(assets, spacings, address(stub), router, factory, registry, address(this));
        require(address(vault) == predicted, "vault address prediction");
    }
}
