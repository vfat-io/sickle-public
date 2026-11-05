// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IMasterchefV3 {
    struct UserPositionInfo {
        uint128 liquidity;
        uint128 boostLiquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 rewardGrowthInside;
        uint256 reward;
        address user;
        uint256 pid;
        uint256 boostMultiplier;
    }

    struct PoolInfo {
        uint256 allocPoint;
        // V3 pool address
        address v3Pool;
        // V3 pool token0 address
        address token0;
        // V3 pool token1 address
        address token1;
        // V3 pool fee
        uint24 fee;
        // total liquidity staking in the pool
        uint256 totalLiquidity;
        // total boost liquidity staking in the pool
        uint256 totalBoostLiquidity;
    }

    function userPositionInfos(
        uint256 tokenId
    ) external view returns (UserPositionInfo memory);
    function poolInfo(
        uint256 pid
    ) external view returns (PoolInfo memory);
    function harvest(
        uint256 _tokenId,
        address _to
    ) external returns (uint256 reward);
    function withdraw(
        uint256 _tokenId,
        address _to
    ) external returns (uint256 reward);
    function pendingCake(
        uint256 _tokenId
    ) external view returns (uint256 reward);
    function nonfungiblePositionManager() external view returns (address);
    function getLatestPeriodInfo(
        address pool
    ) external view returns (uint256 rewardPerSecond, uint256 endTime);

    struct CollectParams {
        uint256 tokenId;
        address to;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(
        CollectParams calldata params
    ) external returns (uint256 amount0, uint256 amount1);
}
