// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Stake DAO V2 RewardVault: an ERC4626 clone whose shares are 1:1
/// with the gauge LP it wraps. The vault never holds the LP; it is sent to the
/// strategy's allocation targets (the Stake DAO Locker, and any sidecar), and
/// share balances are kept by the Accountant.
interface IStakeDaoRewardVault {
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256);

    /// @notice Claims the vault's extra reward tokens for `msg.sender`. The
    /// main protocol reward (CRV) is claimed from the Accountant instead.
    function claim(
        address[] calldata tokens,
        address receiver
    ) external returns (uint256[] memory amounts);

    function earned(
        address account,
        address token
    ) external view returns (uint128);

    function getRewardTokens() external view returns (address[] memory);

    function isRewardToken(
        address rewardToken
    ) external view returns (bool);

    function balanceOf(
        address account
    ) external view returns (uint256);

    function asset() external view returns (address);

    function gauge() external view returns (address);

    function ACCOUNTANT() external view returns (address);

    function PROTOCOL_ID() external view returns (bytes4);
}
