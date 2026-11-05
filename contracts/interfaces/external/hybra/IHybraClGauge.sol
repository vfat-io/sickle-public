// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHybraClGauge {
    /* ========== EVENTS ========== */

    event ClaimFees(address indexed from, uint256 claimed0, uint256 claimed1);
    event Deposit(address indexed user, uint256 amount);
    event EmergencyActivated(address indexed gauge, uint256 timestamp);
    event EmergencyDeactivated(address indexed gauge, uint256 timestamp);
    event Harvest(address indexed user, uint256 reward);
    event OwnershipTransferred(
        address indexed previousOwner, address indexed newOwner
    );
    event RewardAdded(uint256 reward);
    event Withdraw(address indexed user, uint256 amount);

    /* ========== VIEW FUNCTIONS ========== */

    function DISTRIBUTION() external view returns (address);

    function DURATION() external view returns (uint256);

    function VE() external view returns (address);

    function balanceOf(
        uint256 tokenId
    ) external view returns (uint256);

    function earned(
        uint256 tokenId
    ) external view returns (uint256);

    function emergency() external view returns (bool);

    function gaugeBalances()
        external
        view
        returns (uint256 token0, uint256 token1);

    function isForPair() external view returns (bool);

    function owner() external view returns (address);

    function poolAddress() external view returns (address);

    function rHYBR() external view returns (address);

    function rewardForDuration() external view returns (uint256);

    function rewardRate() external view returns (uint256);

    function rewardRateByEpoch(
        uint256
    ) external view returns (uint256);

    /* ========== STATE-CHANGING FUNCTIONS ========== */

    function activateEmergencyMode() external;

    function claimFees() external returns (uint256 claimed0, uint256 claimed1);

    function deposit(
        uint256 tokenId
    ) external;

    function getReward(
        uint256 tokenId,
        address account,
        uint8 redeemType
    ) external;

    function notifyRewardAmount(
        address token,
        uint256 rewardAmount
    ) external returns (uint256 currentRate);

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure returns (bytes4);

    function renounceOwnership() external;

    function setInternalBribe(
        address _int
    ) external;

    function stopEmergencyMode() external;

    function transferOwnership(
        address newOwner
    ) external;

    function withdraw(
        uint256 tokenId,
        uint8 redeemType
    ) external;
}
