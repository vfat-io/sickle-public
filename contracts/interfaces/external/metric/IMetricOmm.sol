// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// Metric ABI subset.
struct MetricPoolImmutables {
    address factory;
    address token0;
    address token1;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
    uint256 initialScaledToken0PerShareE18;
    uint256 initialScaledToken1PerShareE18;
    uint256 minimalOperationalLiquidity;
    address immutablePriceProvider;
    int256 lowestBin;
    int256 highestBin;
    address extension1;
    address extension2;
    address extension3;
    address extension4;
    address extension5;
    address extension6;
    address extension7;
    uint256 beforeAddLiquidityOrder;
    uint256 afterAddLiquidityOrder;
    uint256 beforeRemoveLiquidityOrder;
    uint256 afterRemoveLiquidityOrder;
    uint256 beforeSwapOrder;
    uint256 afterSwapOrder;
}

struct MetricLiquidityDelta {
    int256[] binIdxs;
    uint256[] shares;
}

struct MetricBinPositionBounds {
    int16 minimalCurBin;
    uint104 minimalPosition;
    int16 maximalCurBin;
    uint104 maximalPosition;
}

interface IMetricOmmFactory {
    function isPool(
        address pool
    ) external view returns (bool);
}

interface IMetricOmmPool {
    function getImmutables() external view returns (MetricPoolImmutables memory);

    function removeLiquidity(
        address owner,
        uint80 salt,
        MetricLiquidityDelta calldata deltas,
        bytes calldata extensionData
    ) external returns (uint256 amount0Removed, uint256 amount1Removed);
}

interface IMetricOmmLiquidityAdder {
    function addLiquidityWeighted(
        address pool,
        address owner,
        uint80 salt,
        MetricLiquidityDelta calldata weightDeltas,
        uint256 maxAmountToken0,
        uint256 maxAmountToken1,
        MetricBinPositionBounds calldata binPositionBounds,
        bytes calldata extensionData
    ) external payable returns (uint256 amount0Added, uint256 amount1Added);
}

interface IMetricOmmDataProvider {
    function positionBinShares(
        address pool,
        address owner,
        uint80 salt,
        int16 bin
    ) external view returns (uint256);

    function binTotalShares(
        address pool,
        int16 bin
    ) external view returns (uint256);

    function binState(
        address pool,
        int16 bin
    )
        external
        view
        returns (
            uint104 token0BalanceScaled,
            uint104 token1BalanceScaled,
            uint16 lengthE6,
            uint16 addFeeBuyE6,
            uint16 addFeeSellE6
        );
}
