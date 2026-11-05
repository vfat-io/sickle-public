// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice `Accountant.vaults(vault)`: a vault's reward accounting.
struct StakeDaoVaultData {
    uint256 integral;
    uint128 supply;
    uint128 feeSubjectAmount;
    uint128 totalAmount;
    uint128 netCredited;
    uint128 reservedHarvestFee;
    uint128 reservedProtocolFee;
}

/// @notice `Accountant.accounts(vault, account)`: one holder's position.
struct StakeDaoAccountData {
    uint128 balance;
    uint256 integral;
    uint256 pendingRewards;
}

/// @notice Stake DAO V2 Accountant: tracks vault share balances and
/// distributes the protocol's main reward token (CRV for Curve).
interface IStakeDaoAccountant {
    /// @notice Claims `msg.sender`'s main reward for the vaults of `gauges`.
    /// @param harvestData Empty to claim only what is already credited, or one
    /// entry per gauge to harvest each gauge first. The harvest fee is paid to
    /// `msg.sender`.
    /// @dev Reverts `NoPendingRewards()` when nothing is claimable.
    function claim(
        address[] calldata gauges,
        bytes[] calldata harvestData
    ) external;

    /// @dev Both getters return all-static tuples, which ABI-encode exactly
    /// as the structs below.
    function vaults(
        address vault
    ) external view returns (StakeDaoVaultData memory);

    function accounts(
        address vault,
        address account
    ) external view returns (StakeDaoAccountData memory);

    function REWARD_TOKEN() external view returns (address);

    function SCALING_FACTOR() external view returns (uint128);

    function getProtocolFeePercent() external view returns (uint128);

    function getHarvestFeePercent() external view returns (uint128);
}
