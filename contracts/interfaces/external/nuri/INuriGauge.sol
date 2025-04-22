// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface INuriGauge {
    function initialize(
        address _stake,
        address _feeDist,
        address _voter,
        bool _forPair
    ) external;

    function getReward(address account, address[] calldata tokens) external;

    function claimFees()
        external
        returns (uint256 claimed0, uint256 claimed1);

    function left(
        address token
    ) external view returns (uint256);

    function rewardsListLength() external view returns (uint256);

    function rewardsList() external view returns (address[] memory);

    function earned(
        address token,
        address account
    ) external view returns (uint256);

    function balanceOf(
        address
    ) external view returns (uint256);

    function notifyRewardAmount(address token, uint256 amount) external;

    struct Reward {
        uint256 rewardRate;
        uint256 periodFinish;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    function rewardData(
        address token
    ) external view returns (Reward memory);

    function deposit(
        uint256 amount
    ) external;

    function withdraw(
        uint256 amount
    ) external;
}
