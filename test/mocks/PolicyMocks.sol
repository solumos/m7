// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IB20Policy, IPolicyRegistry} from "../../src/interfaces/IB20Policy.sol";

/// @dev Blocklist semantics like live policy 5: policy 0 always allows; any other id allows unless blocked.
contract PolicyRegistryMock is IPolicyRegistry {
    mapping(uint64 => mapping(address => bool)) public blocked;
    bool public broken;

    function setBlocked(uint64 id, address account, bool value) external {
        blocked[id][account] = value;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function isAuthorized(uint64 id, address account) external view returns (bool) {
        require(!broken, "registry unavailable");
        return id == 0 || !blocked[id][account];
    }
}

/// @dev B20 policy surface for test tokens. Scope constants match live B20s; every scope defaults to policy 0.
abstract contract B20PolicyMixin is IB20Policy {
    mapping(bytes32 => uint64) private _policyIds;
    bool public policyLookupReverts;

    function TRANSFER_SENDER_POLICY() public pure returns (bytes32) {
        return keccak256("TRANSFER_SENDER_POLICY");
    }

    function TRANSFER_RECEIVER_POLICY() public pure returns (bytes32) {
        return keccak256("TRANSFER_RECEIVER_POLICY");
    }

    function TRANSFER_EXECUTOR_POLICY() public pure returns (bytes32) {
        return keccak256("TRANSFER_EXECUTOR_POLICY");
    }

    function policyId(bytes32 scope) public view returns (uint64) {
        require(!policyLookupReverts, "policy lookup failed");
        return _policyIds[scope];
    }

    function setPolicyId(bytes32 scope, uint64 id) external {
        _policyIds[scope] = id;
    }

    function setPolicyLookupReverts(bool value) external {
        policyLookupReverts = value;
    }
}

/// @dev Enforces its own sender, receiver and executor policies through the registry, like a B20 transfer.
contract B20LikeToken is ERC20, B20PolicyMixin {
    uint8 private immutable _tokenDecimals;
    IPolicyRegistry public immutable registry;
    bool public paused;

    constructor(uint8 decimals_, IPolicyRegistry registry_) ERC20("B20-like asset", "B20") {
        _tokenDecimals = decimals_;
        registry = registry_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(!paused, "transfers paused");
            _enforce(TRANSFER_SENDER_POLICY(), from);
            _enforce(TRANSFER_RECEIVER_POLICY(), to);
            _enforce(TRANSFER_EXECUTOR_POLICY(), msg.sender);
        }
        super._update(from, to, amount);
    }

    function _enforce(bytes32 scope, address account) private view {
        uint64 id = policyId(scope);
        if (id != 0) require(registry.isAuthorized(id, account), "policy forbids");
    }
}
