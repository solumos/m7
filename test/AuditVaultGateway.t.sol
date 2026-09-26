// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {VaultTestToken, VaultTestRouter} from "./M7CapVault.t.sol";
import {GatewayFactory, GatewayRouter} from "./mocks/GatewayMocks.sol";

/// @dev Models address-specific sender and receiver policy, not a legal eligibility determination.
contract AuditPolicyToken is ERC20 {
    uint8 private immutable _decimals;
    address public excluded;

    constructor(uint8 decimals_) ERC20("Policy token", "POL") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setExcluded(address account) external {
        excluded = account;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(excluded == address(0) || (from != excluded && to != excluded), "address excluded");
        super._update(from, to, amount);
    }
}

/// @dev Audit reproduction only; no production behavior is changed.
contract AuditVaultGatewayTest is Test {
    function testAuditStockAddressExclusionDoesNotPropagateToGatewayUser() public {
        IERC20[8] memory tokens;
        uint256[8] memory seed;
        int24[7] memory routes;
        address excludedUser = address(0xa11ce);
        for (uint256 i; i < 8; ++i) {
            tokens[i] = new AuditPolicyToken(i == 7 ? 6 : 8);
            AuditPolicyToken(address(tokens[i])).mint(address(this), 1_000e8);
            if (i < 7) {
                seed[i] = 10e8;
                routes[i] = 10;
            }
        }
        GatewayFactory factory = new GatewayFactory();
        GatewayRouter router = new GatewayRouter(address(factory), address(tokens[7]));
        M7CapVault vault = new M7CapVault(tokens, address(this), router, factory, address(this));
        USDCGateway gateway = new USDCGateway(IM7CapVault(address(vault)), router, factory);
        for (uint256 i; i < 8; ++i) {
            AuditPolicyToken(address(tokens[i])).mint(address(router), 1_000e8);
            tokens[i].approve(address(vault), type(uint256).max);
            if (i < 7) {
                factory.setPool(address(tokens[i]), address(tokens[7]), 10, address(router));
            }
        }
        vault.bootstrap(seed, address(this));
        AuditPolicyToken(address(tokens[0])).setExcluded(excludedUser);

        // The stock's own receiver policy rejects delivery to this user.
        vm.expectRevert("address excluded");
        tokens[0].transfer(excludedUser, 1);

        // Nevertheless, the user can acquire the stock's pooled exposure with USDC.
        AuditPolicyToken(address(tokens[7])).mint(excludedUser, 100e6);
        vm.startPrank(excludedUser);
        tokens[7].approve(address(gateway), 1e6);
        assertEq(gateway.mintWithUSDC(10e18, 1e6, excludedUser, block.timestamp, routes), 0.7e6);
        assertEq(vault.balanceOf(excludedUser), 10e18);
        assertEq(tokens[0].balanceOf(excludedUser), 0);

        uint256[8] memory amounts = vault.quoteRedeem(10e18);
        vm.expectRevert("address excluded");
        vault.redeemBasket(10e18, amounts, excludedUser, block.timestamp);

        // The gateway is the B20 sender/receiver, so the excluded user can still cash out.
        vault.approve(address(gateway), 10e18);
        assertEq(gateway.redeemToUSDC(10e18, 0.7e6, excludedUser, block.timestamp, routes), 0.7e6);
        assertEq(tokens[7].balanceOf(excludedUser), 100e6);
        assertEq(vault.balanceOf(excludedUser), 0);
        vm.stopPrank();
    }

    function testRegressionAllCirculatingSharesRedeemedAndRefilledPreservesBasket() public {
        IERC20[8] memory tokens;
        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            tokens[i] = new VaultTestToken(i == 7 ? 6 : 8);
            VaultTestToken(address(tokens[i])).mint(address(this), 1_000e8);
            if (i < 7) seed[i] = (i + 1) * 1e8;
        }
        VaultTestRouter router = new VaultTestRouter();
        M7CapVault vault = new M7CapVault(tokens, address(this), router, router, address(this));
        for (uint256 i; i < 8; ++i) {
            tokens[i].approve(address(vault), type(uint256).max);
        }
        vault.bootstrap(seed, address(this));

        // The seed holds 1, 2, ... 7 human stock tokens, hence a 1:7 quantity ratio.
        assertEq(tokens[6].balanceOf(address(vault)), 7 * tokens[0].balanceOf(address(vault)));
        uint256 circulating = vault.balanceOf(address(this));
        uint256[8] memory amounts = vault.quoteRedeem(circulating);
        vault.redeemBasket(circulating, amounts, address(0xb0b), block.timestamp);

        assertEq(vault.totalSupply(), vault.LOCKED_SHARES());
        for (uint256 i; i < 7; ++i) {
            // The meaningful reserve retains every stock's original quantity proportion.
            assertEq(tokens[i].balanceOf(address(vault)), (i + 1) * 1e6);
        }

        // Refilling the original circulating supply preserves the original 1:7 ratio.
        uint256[8] memory quote = vault.quoteMint(990e18);
        for (uint256 i; i < 7; ++i) {
            assertEq(quote[i], (i + 1) * 99e6);
        }
        vault.mintBasket(990e18, quote, address(0xa11ce), block.timestamp);
        assertEq(tokens[0].balanceOf(address(vault)), 1e8);
        assertEq(tokens[6].balanceOf(address(vault)), 7 * tokens[0].balanceOf(address(vault)));
    }
}
