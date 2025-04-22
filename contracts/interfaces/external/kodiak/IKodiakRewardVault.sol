// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IKodiakRewardVault {
    /// @notice Deposit staking tokens
    /// @param amount Amount to deposit
    function stake(
        uint256 amount
    ) external;

    /// @notice Withdraw staked tokens
    /// @param amount Amount to withdraw
    function withdraw(
        uint256 amount
    ) external;

    /// @notice Claim rewards for an account, send them to recipient
    /// @param account The staker's address
    /// @param recipient Address to send the rewards
    /// @return rewardAmount The amount of reward claimed
    function getReward(
        address account,
        address recipient
    ) external returns (uint256);

    /// @notice Get balance of staked tokens for an account
    /// @param account The user's address
    /// @return balance The amount of staked tokens
    function balanceOf(
        address account
    ) external view returns (uint256);

    /// @notice Get the amount of rewards earned by an account
    /// @param account The user's address
    /// @return earnedRewards The amount of rewards earned
    function earned(
        address account
    ) external view returns (uint256);

    function stakeToken() external view returns (address);
}
