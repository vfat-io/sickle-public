// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IMetricOmmFactory,
    MetricPoolImmutables
} from "contracts/interfaces/external/metric/IMetricOmm.sol";
import {
    MetricAddLiquidity,
    MetricRemoveLiquidity,
    MetricPosition
} from "contracts/structs/MetricStrategyStructs.sol";

interface IMetricLiquidityConnector {
    function metricFactory() external view returns (IMetricOmmFactory);
    function poolInfo(
        address pool
    ) external view returns (MetricPoolImmutables memory);
    function positionShares(
        MetricPosition calldata position,
        address owner,
        int256[] calldata bins
    ) external view returns (uint256[] memory);
    function underlyingAmounts(
        MetricPosition calldata position,
        address owner,
        int256[] calldata bins
    ) external view returns (uint256, uint256);
    function addLiquidity(
        MetricAddLiquidity calldata params
    ) external payable;
    function removeLiquidity(
        MetricRemoveLiquidity calldata params
    ) external payable;
}
