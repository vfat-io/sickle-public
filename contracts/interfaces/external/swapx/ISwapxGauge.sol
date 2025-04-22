// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface ISwapxGauge {
    function claimFees()
        external
        returns (uint256 claimed0, uint256 claimed1);

    /// @notice Withdraw LP tokens for user
    /// @param _amount .
    function withdraw(
        uint256 _amount
    ) external;

    /// @notice Deposit LP tokens into gauge for msg.sender
    /// @param _amount .
    function deposit(
        uint256 _amount
    ) external;

    function getReward() external;

    /// @notice Address of the pool LP token which is deposited (staked) for
    /// rewards
    function TOKEN() external view returns (address);

    /// @notice Address of the token rewarded to stakers
    function rewardToken() external view returns (address);

    /// @notice Current reward rate of rewardToken to distribute per second
    function rewardRate() external view returns (uint256);

    /// @notice Amount of stakingToken deposited for rewards
    function _totalSupply() external view returns (uint256);

    /// @notice Get the amount of stakingToken deposited by an account
    function balanceOf(
        address
    ) external view returns (uint256);

    /// @notice Returns accrued balance to date from last claim / first deposit.
    function earned(
        address _account
    ) external view returns (uint256 _earned);
}
