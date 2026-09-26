// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Subset of Base's IB20 policy surface (github.com/base/base-std, src/interfaces/IB20.sol).
interface IB20Policy {
    function TRANSFER_SENDER_POLICY() external view returns (bytes32);
    function TRANSFER_RECEIVER_POLICY() external view returns (bytes32);
    function TRANSFER_EXECUTOR_POLICY() external view returns (bytes32);
    function policyId(bytes32 policyScope) external view returns (uint64);
}

/// @dev Subset of Base's IPolicyRegistry precompile (0x8453000000000000000000000000000000000002).
interface IPolicyRegistry {
    function isAuthorized(uint64 policyId, address account) external view returns (bool);
}

/// @dev Lets the vault confirm at construction that its controller is bound to it.
interface IControllerBinding {
    function vault() external view returns (address);
}
