// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct IncentiveKey {
    address rewardToken;
    address bonusRewardToken;
    address pool;
    uint256 nonce;
}

interface IAtlantisIncentiveMaker {
    struct IncentiveParams {
        uint128 reward;
        uint128 bonusReward;
        uint128 rewardRate;
        uint128 bonusRewardRate;
        uint24 minimalPositionWidth;
    }

    // --- Events ---
    event EmergencyWithdraw(bool newStatus);
    event EternalFarmingCreated(
        address indexed rewardToken,
        address indexed bonusRewardToken,
        address indexed pool,
        address virtualPool,
        uint256 nonce,
        uint256 reward,
        uint256 bonusReward,
        uint24 minimalAllowedPositionWidth
    );
    event FarmEnded(
        uint256 indexed tokenId,
        bytes32 indexed incentiveId,
        address indexed rewardAddress,
        address bonusRewardToken,
        address owner,
        uint256 reward,
        uint256 bonusReward
    );
    event FarmEntered(
        uint256 indexed tokenId, bytes32 indexed incentiveId, uint128 liquidity
    );
    event FarmingCenter(address indexed farmingCenter);
    event IncentiveDeactivated(bytes32 indexed incentiveId);
    event RewardAmountsDecreased(
        uint256 rewardAmount, uint256 bonusRewardAmount, bytes32 incentiveId
    );
    event RewardClaimed(
        address indexed to,
        uint256 reward,
        address indexed rewardAddress,
        address indexed owner
    );
    event RewardsAdded(
        uint256 rewardAmount, uint256 bonusRewardAmount, bytes32 incentiveId
    );
    event RewardsCollected(
        uint256 rewardAmount,
        uint256 bonusRewardAmount,
        bytes32 incentiveId,
        uint256 tokenId
    );
    event RewardsRatesChanged(
        uint128 rewardRate, uint128 bonusRewardRate, bytes32 incentiveId
    );

    // --- Errors ---
    error anotherFarmingIsActive();
    error claimToZeroAddress();
    error emergencyActivated();
    error farmDoesNotExist();
    error incentiveNotExist();
    error incentiveStopped();
    error invalidPool();
    error invalidTokenAmount();
    error minimalPositionWidthTooWide();
    error pluginNotConnected();
    error poolReentrancyLock();
    error positionIsTooNarrow();
    error reentrancyLock();
    error tokenAlreadyFarmed();
    error zeroLiquidity();
    error zeroRewardAmount();

    // --- View Functions ---
    function FARMINGS_ADMINISTRATOR_ROLE() external view returns (bytes32);
    function INCENTIVE_MAKER_ROLE() external view returns (bytes32);
    function farmingCenter() external view returns (address);
    function isEmergencyWithdrawActivated() external view returns (bool);
    function numOfIncentives() external view returns (uint256);
    function nonfungiblePositionManager() external view returns (address);

    function incentiveKeys(
        address pool
    )
        external
        view
        returns (
            address rewardToken,
            address bonusRewardToken,
            address poolAddress,
            uint256 nonce
        );

    function incentives(
        bytes32 incentiveId
    )
        external
        view
        returns (
            uint128 totalReward,
            uint128 bonusReward,
            address virtualPoolAddress,
            uint24 minimalPositionWidth,
            bool deactivated,
            address pluginAddress
        );

    function isIncentiveDeactivated(
        bytes32 incentiveId
    ) external view returns (bool res);

    function rewards(
        address owner,
        address rewardToken
    ) external view returns (uint256 rewardAmount);

    function farms(
        uint256 tokenId,
        bytes32 incentiveId
    )
        external
        view
        returns (
            uint128 liquidity,
            int24 tickLower,
            int24 tickUpper,
            uint256 innerRewardGrowth0,
            uint256 innerRewardGrowth1
        );

    function getRewardInfo(
        IncentiveKey calldata key,
        uint256 tokenId
    ) external view returns (uint256 reward, uint256 bonusReward);

    // --- State-Changing Functions ---
    function addRewards(
        IncentiveKey calldata key,
        uint128 rewardAmount,
        uint128 bonusRewardAmount
    ) external;
    function claimReward(
        address rewardToken,
        address to,
        uint256 amountRequested
    ) external returns (uint256 reward);
    function claimRewardFrom(
        address rewardToken,
        address from,
        address to,
        uint256 amountRequested
    ) external returns (uint256 reward);
    function collectRewards(
        IncentiveKey calldata key,
        uint256 tokenId,
        address _owner
    ) external returns (uint256 reward, uint256 bonusReward);
    function createEternalFarming(
        IncentiveKey calldata key,
        IncentiveParams calldata params,
        address plugin
    ) external returns (address virtualPool);
    function deactivateIncentive(
        IncentiveKey calldata key
    ) external;
    function decreaseRewardsAmount(
        IncentiveKey calldata key,
        uint128 rewardAmount,
        uint128 bonusRewardAmount
    ) external;
    function enterFarming(
        IncentiveKey calldata key,
        uint256 tokenId
    ) external;
    function exitFarming(
        IncentiveKey calldata key,
        uint256 tokenId,
        address _owner
    ) external;
    function setEmergencyWithdrawStatus(
        bool newStatus
    ) external;
    function setFarmingCenterAddress(
        address _farmingCenter
    ) external;
    function setRates(
        IncentiveKey calldata key,
        uint128 rewardRate,
        uint128 bonusRewardRate
    ) external;
}
