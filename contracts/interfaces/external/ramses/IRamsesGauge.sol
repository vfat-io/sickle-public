// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IRamsesGauge {
    function notifyRewardAmount(address token, uint256 amount) external;

    function getReward(address account, address[] memory tokens) external;

    function claimFees()
        external
        returns (uint256 claimed0, uint256 claimed1);

    function left(address token) external view returns (uint256);

    function isForPair() external view returns (bool);

    function whitelistNotifiedRewards(address token) external;

    function removeRewardWhitelist(address token) external;

    function rewardsListLength() external view returns (uint256);

    function rewards(uint256 index) external view returns (address);

    function earned(
        address token,
        address account
    ) external view returns (uint256);

    function balanceOf(address) external view returns (uint256);

    function derivedBalances(address) external view returns (uint256);

    function rewardRate(address) external view returns (uint256);

    function deposit(uint256 amount, uint256 tokenId) external;

    function withdraw(uint256 amount) external;
}
