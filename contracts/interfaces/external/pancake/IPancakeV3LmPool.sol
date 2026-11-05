// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPancakeV3LmPool {
    /**
     * @notice Struct representing LM tick information
     */
    struct LmTick {
        uint128 liquidityGross; // Total liquidity at this tick
        int128 liquidityNet; // Net liquidity change at this tick
        uint256 rewardGrowthOutsideX128; // Reward growth outside this tick
    }

    /**
     * @notice Returns the reward precision constant
     */
    function REWARD_PRECISION() external view returns (uint256);

    /**
     * @notice Returns reward growth inside a tick range
     * @param tickLower The lower tick of the range
     * @param tickUpper The upper tick of the range
     * @return rewardGrowthInsideX128 The reward growth inside the tick range
     */
    function getRewardGrowthInside(
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256 rewardGrowthInsideX128);

    /**
     * @notice Returns the timestamp of the last reward accumulation
     */
    function lastRewardTimestamp() external view returns (uint32);

    /**
     * @notice Returns the total liquidity eligible for LM rewards
     */
    function lmLiquidity() external view returns (uint128);

    /**
     * @notice Returns LM tick information for a given tick
     * @param tick The tick to query
     * @return liquidityGross Total liquidity at this tick
     * @return liquidityNet Net liquidity change at this tick
     * @return rewardGrowthOutsideX128 Reward growth outside this tick
     */
    function lmTicks(
        int24 tick
    )
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 rewardGrowthOutsideX128
        );

    /**
     * @notice Returns the MasterChef V3 contract address
     */
    function masterChef() external view returns (address);

    /**
     * @notice Returns the associated PancakeSwap V3 pool address
     */
    function pool() external view returns (address);

    /**
     * @notice Returns the global reward growth per liquidity
     */
    function rewardGrowthGlobalX128() external view returns (uint256);
}
