// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    MetricLiquidityDelta,
    MetricBinPositionBounds
} from "contracts/interfaces/external/metric/IMetricOmm.sol";
import { SwapParams } from "contracts/structs/SwapStructs.sol";

struct MetricPosition {
    address pool;
    uint80 salt;
}

struct MetricAddLiquidity {
    MetricPosition position;
    /// @dev Relative share weights scaled by the adder to fit the token caps.
    /// Bin indices must be strictly increasing.
    MetricLiquidityDelta weights;
    /// @dev Post-swap spending caps; MAX uses the available balance.
    uint256 amount0Max;
    uint256 amount1Max;
    uint256[] minShares;
    MetricBinPositionBounds bounds;
    bytes extensionData;
}

struct MetricRemoveLiquidity {
    MetricPosition position;
    /// @dev MAX burns all shares in that bin for this Sickle and salt.
    MetricLiquidityDelta deltas;
    /// @dev Minimum underlying proceeds before fees and swaps.
    uint256 amount0Min;
    uint256 amount1Min;
    bytes extensionData;
}

struct MetricIncrease {
    address[] tokensIn;
    uint256[] amountsIn;
    SwapParams[] swaps;
    MetricAddLiquidity liquidity;
    address[] sweepTokens;
}

struct MetricOutput {
    /// @dev ERC20 or a TransferLib native sentinel. Native/wrapped aliases
    /// count as one output asset.
    address token;
    /// @dev Minimum net proceeds, excluding pre-existing balances.
    /// Native output includes both native and wrapped-native proceeds.
    uint256 minAmount;
}

struct MetricWithdraw {
    MetricRemoveLiquidity liquidity;
    SwapParams[] swaps;
    MetricOutput[] outputs;
    address[] sweepTokens;
}
