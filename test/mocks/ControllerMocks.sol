// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptimisticOracleV3} from "../../src/interfaces/IOptimisticOracleV3.sol";
import {IAggregatorV3, ICoinbaseOracleRegistry} from "../../src/Valuation.sol";
import {Swap} from "../../src/Types.sol";

contract ControllerToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Controller test token", "TEST") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

contract ControllerFeed is IAggregatorV3 {
    uint8 public immutable decimals;
    uint80 public round = 1;
    uint80 public answeredRound = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        set(answer_, block.timestamp);
    }

    function set(int256 answer_, uint256 updatedAt_) public {
        answer = answer_;
        updatedAt = updatedAt_;
        startedAt = block.timestamp > 2 hours ? block.timestamp - 2 hours : 0;
    }

    function setStartedAt(uint256 startedAt_) external {
        startedAt = startedAt_;
    }

    function setRounds(uint80 round_, uint80 answeredRound_) external {
        round = round_;
        answeredRound = answeredRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, startedAt, updatedAt, answeredRound);
    }
}

contract ControllerRegistry is ICoinbaseOracleRegistry {
    mapping(address => bool) public paused;
    uint256 public multiplier = 1e18;

    function setPaused(address token, bool paused_) external {
        paused[token] = paused_;
    }

    function setMultiplier(uint256 multiplier_) external {
        multiplier = multiplier_;
    }

    function getOracleParams(address token) external view returns (uint256, bool) {
        return (multiplier, paused[token]);
    }
}

contract ControllerOracle is IOptimisticOracleV3 {
    mapping(bytes32 => Assertion) private _assertions;
    mapping(bytes32 => bool) public disputedResolved;
    uint256 public minimumBond = 500e6;
    uint256 public nonce;
    uint256 public syncCount;
    bytes public lastClaim;

    function defaultIdentifier() external pure returns (bytes32) {
        return "ASSERT_TRUTH";
    }

    function syncUmaParams(bytes32, address) external {
        ++syncCount;
    }

    function getMinimumBond(address) external view returns (uint256) {
        return minimumBond;
    }

    function setMinimumBond(uint256 minimumBond_) external {
        minimumBond = minimumBond_;
    }

    function getAssertion(bytes32 id) external view returns (Assertion memory) {
        return _assertions[id];
    }

    function dispute(bytes32 id) external {
        _assertions[id].disputer = msg.sender;
    }

    function resolveDispute(bytes32 id, bool result) external {
        disputedResolved[id] = true;
        _assertions[id].settlementResolution = result;
    }

    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 id) {
        // Match live Base: the immutable default remains deprecated, while this replacement is whitelisted.
        require(identifier == bytes32("ASSERT_TRUTH2"), "Unsupported identifier");
        require(bond >= minimumBond, "low bond");
        require(currency.transferFrom(msg.sender, address(this), bond));
        id = keccak256(abi.encode(++nonce, claim));
        lastClaim = claim;
        Assertion storage a = _assertions[id];
        a.asserter = asserter;
        a.assertionTime = uint64(block.timestamp);
        a.expirationTime = uint64(block.timestamp) + liveness;
        a.currency = currency;
        a.bond = bond;
        a.identifier = identifier;
        a.domainId = domainId;
        a.callbackRecipient = callbackRecipient;
        a.escalationManagerSettings.escalationManager = escalationManager;
    }

    function settleAndGetAssertionResult(bytes32 id) external returns (bool result) {
        Assertion storage a = _assertions[id];
        if (a.settled) return a.settlementResolution;
        require(block.timestamp >= a.expirationTime, "liveness");
        require(a.disputer == address(0) || disputedResolved[id], "unresolved dispute");
        result = a.disputer == address(0) || a.settlementResolution;
        a.settlementResolution = result;
        a.settled = true;
        require(a.currency.transfer(result ? a.asserter : a.disputer, a.bond));
    }
}

/// @dev Test-only balance mutation simulates arbitrary swap results so postconditions can be adversarially tested.
contract ControllerVault is ERC20 {
    IERC20[8] public assets;
    uint256[8] public afterBalances;
    bool public mutate;
    bool public dilute;
    uint256 public calls;
    ControllerFeed public changeFeed;

    constructor(address[8] memory assets_) ERC20("Test vault", "TEST") {
        for (uint256 i; i < 8; ++i) {
            assets[i] = IERC20(assets_[i]);
        }
        _mint(msg.sender, 100e18);
    }

    function setAfter(uint256[8] memory amounts) external {
        afterBalances = amounts;
        mutate = true;
    }

    function setDilute(bool value) external {
        dilute = value;
    }

    function setChangeFeed(ControllerFeed feed) external {
        changeFeed = feed;
    }

    function rebalance(Swap[] calldata, uint256 deadline) external {
        require(block.timestamp <= deadline, "deadline");
        ++calls;
        if (mutate) {
            for (uint256 i; i < 8; ++i) {
                ControllerToken token = ControllerToken(address(assets[i]));
                uint256 beforeBalance = token.balanceOf(address(this));
                if (afterBalances[i] > beforeBalance) {
                    token.mint(address(this), afterBalances[i] - beforeBalance);
                } else {
                    token.burn(address(this), beforeBalance - afterBalances[i]);
                }
            }
        }
        if (dilute) _mint(msg.sender, 1e18);
        if (address(changeFeed) != address(0)) changeFeed.set(1e8, block.timestamp);
    }
}
