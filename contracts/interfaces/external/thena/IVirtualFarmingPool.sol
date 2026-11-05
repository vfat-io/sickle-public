// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVirtualFarmingPool {
    /**
     * @notice Struct representing tick information
     */
    struct TickInfo {
        uint256 liquidityTotal; // Total liquidity at this tick
        int128 liquidityDelta; // Liquidity change at this tick
        int24 prevTick; // Previous tick in the linked list
        int24 nextTick; // Next tick in the linked list
        uint256 outerFeeGrowth0Token; // Fee growth outside for token0
        uint256 outerFeeGrowth1Token; // Fee growth outside for token1
    }

    /**
     * @notice Returns the current active liquidity
     */
    function currentLiquidity() external view returns (uint128);

    /**
     * @notice Returns whether the farming center is deactivated
     */
    function deactivated() external view returns (bool);

    /**
     * @notice Returns the farming contract address
     */
    function farmingAddress() external view returns (address);

    /**
     * @notice Returns reward growth inside a tick range
     * @param bottomTick The lower tick of the range
     * @param topTick The upper tick of the range
     * @return rewardGrowthInside0 Reward growth inside for token0
     * @return rewardGrowthInside1 Reward growth inside for token1
     */
    function getInnerRewardsGrowth(
        int24 bottomTick,
        int24 topTick
    )
        external
        view
        returns (uint256 rewardGrowthInside0, uint256 rewardGrowthInside1);

    /**
     * @notice Returns the current global tick
     */
    function globalTick() external view returns (int24);

    /**
     * @notice Returns the plugin contract address
     */
    function plugin() external view returns (address);

    /**
     * @notice Returns the previous timestamp when rewards were last updated
     */
    function prevTimestamp() external view returns (uint32);

    /**
     * @notice Returns the current reward rates for both tokens
     * @return rate0 Reward rate for token0
     * @return rate1 Reward rate for token1
     */
    function rewardRates()
        external
        view
        returns (uint128 rate0, uint128 rate1);

    /**
     * @notice Returns the current reward reserves for both tokens
     * @return reserve0 Reward reserve for token0
     * @return reserve1 Reward reserve for token1
     */
    function rewardReserves()
        external
        view
        returns (uint128 reserve0, uint128 reserve1);

    /**
     * @notice Returns tick information for a given tick ID
     * @param tickId The tick ID to query
     * @return liquidityTotal Total liquidity at this tick
     * @return liquidityDelta Liquidity change at this tick
     * @return prevTick Previous tick in the linked list
     * @return nextTick Next tick in the linked list
     * @return outerFeeGrowth0Token Fee growth outside for token0
     * @return outerFeeGrowth1Token Fee growth outside for token1
     */
    function ticks(
        int24 tickId
    )
        external
        view
        returns (
            uint256 liquidityTotal,
            int128 liquidityDelta,
            int24 prevTick,
            int24 nextTick,
            uint256 outerFeeGrowth0Token,
            uint256 outerFeeGrowth1Token
        );

    /**
     * @notice Returns the total reward growth for both tokens
     * @return rewardGrowth0 Total reward growth for token0
     * @return rewardGrowth1 Total reward growth for token1
     */
    function totalRewardGrowth()
        external
        view
        returns (uint256 rewardGrowth0, uint256 rewardGrowth1);
}
