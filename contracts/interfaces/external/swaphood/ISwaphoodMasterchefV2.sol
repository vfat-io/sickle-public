// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/// @notice Interface for the externally accessible API of MasterchefSwapHood.
interface ISwaphoodMasterchefV2 {
    struct PoolInfo {
        address stakingFarm;
        uint256 allocPoint;
    }

    struct StakingRewardsInfo {
        address stakingRewards;
    }

    event OwnershipTransferred(
        address indexed previousOwner, address indexed newOwner
    );
    event GaugeKilled(address indexed gauge);
    event GaugeRevived(address indexed gauge);
    event DistributeReward(
        address indexed sender, address indexed gauge, uint256 amount
    );
    event GaugeCreated(
        address indexed gauge, address creator, address indexed pool
    );
    event NotifyReward(
        address indexed sender, address indexed reward, uint256 amount
    );

    // Ownable
    function owner() external view returns (address);
    function renounceOwnership() external;
    function transferOwnership(
        address newOwner
    ) external;

    // Configuration and global state
    function stakingRewardsGenesis() external view returns (uint256);
    function totalAllocPoint() external view returns (uint256);
    function rewardsToken() external view returns (address);
    function globalHoodPerSecond() external view returns (uint256);
    function masterchefV3() external view returns (address);
    function pairFeesV3() external view returns (address);
    function stakingRewardsFactory() external view returns (address);
    function governor() external view returns (address);

    // Pool and gauge getters
    function isFarm(
        address farm
    ) external view returns (bool);
    function stakingRewardsInfoByStakingFarmAddress(
        address farm
    ) external view returns (address stakingRewards);
    function poolPidByStakingFarmAddress(
        address farm
    ) external view returns (uint256);
    function poolInfo(
        uint256 index
    ) external view returns (address stakingFarm, uint256 allocPoint);
    function gauges(
        address pool
    ) external view returns (address);
    function poolForGauge(
        address gauge
    ) external view returns (address);
    function isGauge(
        address gauge
    ) external view returns (bool);
    function isAlive(
        address gauge
    ) external view returns (bool);
    function isV3Gauge(
        address gauge
    ) external view returns (bool);
    function pools(
        uint256 index
    ) external view returns (address);
    function poolsLength() external view returns (uint256);

    // Farm creation and reward minting
    function createFarmV2(
        address pool,
        uint256 farmStartTime
    ) external;
    function createFarmV3(
        address v3Pool,
        uint256 farmStartTime
    ) external;
    function mintRewards(
        address receiver,
        uint256 amount
    ) external;
    function pullExtraTokens(
        address token,
        uint256 amount
    ) external;

    // Pool updates and allocation
    function massUpdatePools() external;
    function updatePool(
        uint256 pid
    ) external;
    function updatePoolsInRange(
        uint256 start,
        uint256 end
    ) external;
    function set(
        uint256 pid,
        uint256 allocPoint
    ) external;
    function setBulk(
        uint256[] calldata pids,
        uint256[] calldata allocs
    ) external;

    // Farm controls
    function setGlobalHoodPerSecondV2(
        uint256 globalHoodPerSecondV2
    ) external;
    function setGlobalHoodPerSecondV3(
        uint256 globalHoodPerSecondV3
    ) external;
    function killFarm(
        address farm,
        bool withUpdate
    ) external;
    function activateFarm(
        address farm,
        bool withUpdate
    ) external;
    function setStakingRewardsGenesis(
        uint256 stakingRewardsGenesis_
    ) external;
    function setMasterchefV3(
        address masterchefV3_
    ) external;
    function setPairFeesV3(
        address pairFeesV3_
    ) external;
    function bulkSetFarmStartTime(
        address[] calldata farms,
        uint256 farmStartTime
    ) external;

    // Fee distribution and reward claiming
    function distribute(
        address gauge
    ) external;
    function distributeAll() external;
    function distributeForPoolsInRange(
        uint256 start,
        uint256 finish
    ) external;
    function distributeForGauges(
        address[] calldata gauges_
    ) external;
    function claimBulkV2Rewards(
        address[] calldata gauges_
    ) external;
}
