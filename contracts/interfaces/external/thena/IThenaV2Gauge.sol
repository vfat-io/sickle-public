// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IThenaV2Gauge {
    function setClaimer(
        address _claimer
    ) external;
    function setDistribution(
        address _distribution
    ) external;
    function setVotingIncentives(
        address _vi
    ) external;
    function setFeeVault(
        address _feeVault
    ) external;
    function activateEmergencyMode() external;
    function stopEmergencyMode() external;
    function addRewardToken(
        address _token
    ) external;
    function removeRewardToken(
        address _token
    ) external;
    function pause(
        bool status
    ) external;

    function rewardTokensLength() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(
        address account
    ) external view returns (uint256);
    function rewardRate(
        address _token
    ) external view returns (uint256);
    function rewardPerToken(
        address _token
    ) external view returns (uint256);
    function rewardForDuration(
        address _token
    ) external view returns (uint256);
    function earned(
        address _account,
        address _token
    ) external view returns (uint256);
    function earnedAll(
        address _account
    ) external view returns (uint256[] memory amounts);
    function periodFinish(
        address _token
    ) external view returns (uint256);

    function depositAll() external;
    function deposit(
        uint256 amount
    ) external;
    function withdrawAllAndHarvest() external;
    function withdrawAll() external;
    function withdraw(
        uint256 amount
    ) external;
    function emergencyWithdraw() external;
    function emergencyWithdrawAmount(
        uint256 _amount
    ) external;
    function getReward() external;
    function getRewardFor(
        address user
    ) external;
    function notifyRewardAmount(address _token, uint256 _amount) external;
    function notifyRewardAmountTransferFrom(
        address _token,
        uint256 _amount
    ) external;
    function claimFees()
        external
        returns (uint256 claimed0, uint256 claimed1);

    // Events
    event RewardAdded(address indexed token, uint256 reward);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Harvest(address indexed user, address indexed token, uint256 reward);
    event ClaimFees(address indexed from, uint256 claimed0, uint256 claimed1);
    event ClaimFees(
        address indexed from, address indexed token, uint256 claimed
    );
    event SetClaimer(address indexed claimer);
    event SetDistribution(address indexed distribution);
    event SetVotingIncentives(address indexed vi);
    event SetFeeVault(address indexed feeVault);
    event ActivateEmergencyMode();
    event StopEmergencyMode();
    event AddRewardToken(address indexed token);
    event RemoveRewardToken(address indexed token);
}
