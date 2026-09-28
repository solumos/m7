// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7Vault} from "../../src/M7Vault.sol";
import {IM7Vault} from "../../src/interfaces/IM7Vault.sol";
import {IControllerBinding, IPolicyRegistry} from "../../src/interfaces/IB20Policy.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../../src/interfaces/ISlipstreamRouter.sol";
import {Swap} from "../../src/Types.sol";

/// @dev Stands in for a controller bound to a predicted vault address and forwards its calls in unit tests.
contract ControllerStub is IControllerBinding {
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function rebalance(Swap[] calldata swaps, uint256 deadline) external {
        IM7Vault(vault).rebalance(swaps, deadline);
    }

    function payReward(address to, uint256 amount) external {
        IM7Vault(vault).payReward(to, amount);
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
    ) internal returns (M7Vault vault, ControllerStub stub) {
        address predicted = vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        stub = new ControllerStub(predicted);
        vault = new M7Vault(assets, spacings, address(stub), router, factory, registry, address(this));
        require(address(vault) == predicted, "vault address prediction");
    }
}
