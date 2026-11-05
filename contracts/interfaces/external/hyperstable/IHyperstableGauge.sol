// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Hyperstable gauge (Velodrome V1 Gauge ABI), e.g.
/// 0x830B9cf9520854DDF885f594f9Da93023244BB13 on HyperEVM.
interface IHyperstableGauge {
    function stake() external view returns (address);

    function balanceOf(
        address account
    ) external view returns (uint256);

    function earned(
        address token,
        address account
    ) external view returns (uint256);

    function isReward(
        address token
    ) external view returns (bool);

    /// @dev `tokenId` attaches a vePEG boost; 0 deposits without one.
    function deposit(
        uint256 amount,
        uint256 tokenId
    ) external;

    function withdraw(
        uint256 amount
    ) external;

    /// @dev Reverts unless called by `account` or the Voter.
    function getReward(
        address account,
        address[] memory tokens
    ) external;

    function notifyRewardAmount(
        address token,
        uint256 amount
    ) external;
}
