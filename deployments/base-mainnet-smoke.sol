// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

interface Vm {
    function startPrank(address, address) external;
    function stopPrank() external;
}

interface Token {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface Vault is Token {
    function totalSupply() external view returns (uint256);
    function quoteRedeem(uint256) external view returns (uint256[8] memory);
    function redeemBasketWithClaims(uint256, uint256[8] calldata, address, uint256) external;
    function claimOf(address) external view returns (uint256[8] memory);
    function assets(uint256) external view returns (address);
}

interface Gateway {
    function mintWithUSDC(uint256, uint256, address, uint256) external returns (uint256);
    function redeemToUSDC(uint256, uint256, address, uint256) external returns (uint256);
}

contract Smoke {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external {
        // Pranks change only the local fork. This script cannot broadcast these calls.
        address user = 0x7C3cf25108a28Bf70dBC52aD2A125f8f64cad90C;
        address receiver = address(0xBEEF);
        Vault vault = Vault(0x1aD2e897e19e659C0AEcdB19C1C714F861865BeE);
        Gateway gateway = Gateway(0xAbA592b5fdC0e3c48a9C1f1F7A3a9aebA17BCf1C);
        Token usdc = Token(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        uint256 supply = vault.totalSupply();
        require(supply > 0, "bootstrap first");
        uint256 shares = vault.balanceOf(user);
        uint256 receiverShares = vault.balanceOf(receiver);
        uint256 deadline = block.timestamp + 900;
        vm.startPrank(user, user);
        require(usdc.approve(address(gateway), 300000));
        gateway.mintWithUSDC(2e18, 300000, user, deadline);
        require(vault.balanceOf(user) == shares + 2e18, "mint share count");
        require(vault.approve(address(gateway), 1e18));
        gateway.redeemToUSDC(1e18, 120000, user, deadline);
        uint256[8] memory minimum = vault.quoteRedeem(1e18);
        vault.redeemBasketWithClaims(1e18, minimum, user, deadline);
        require(vault.balanceOf(user) == shares, "round trip share count");
        require(vault.transfer(receiver, 1e16));
        require(vault.balanceOf(receiver) == receiverShares + 1e16, "transfer");
        require(usdc.approve(address(gateway), 0));
        vm.stopPrank();
        vm.startPrank(receiver, receiver);
        require(vault.transfer(user, 1e16));
        vm.stopPrank();
        require(vault.balanceOf(user) == shares && vault.totalSupply() == supply, "supply conservation");
        uint256[8] memory claims = vault.claimOf(user);
        for (uint256 i; i < 8; i++) {
            require(claims[i] == 0, "unexpected deferred claim");
            require(Token(vault.assets(i)).balanceOf(address(gateway)) == 0, "gateway retained assets");
        }
    }
}
