// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CurveLiquidityConnector } from "./CurveLiquidityConnector.sol";
import {
    ICurveLiquidityResolver,
    CurveLiquidityPool
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    ICurveTwoCoinPool,
    ICurveThreeCoinPool,
    ICurveFourCoinPool
} from "contracts/interfaces/external/curve/ICurveLiquidityPools.sol";

abstract contract CurveFixedLiquidityConnector is CurveLiquidityConnector {
    constructor(
        ICurveLiquidityResolver resolver_,
        address weth_
    ) CurveLiquidityConnector(resolver_, weth_) { }

    function _addLiquidity(
        CurveLiquidityPool memory info,
        uint256[] memory amounts,
        uint256 minimum,
        uint256 value
    ) internal override {
        if (amounts.length == 2) {
            ICurveTwoCoinPool(info.pool).add_liquidity{ value: value }(
                [amounts[0], amounts[1]], minimum
            );
        } else if (amounts.length == 3) {
            ICurveThreeCoinPool(info.pool).add_liquidity{ value: value }(
                [amounts[0], amounts[1], amounts[2]], minimum
            );
        } else {
            ICurveFourCoinPool(info.pool).add_liquidity{ value: value }(
                [amounts[0], amounts[1], amounts[2], amounts[3]], minimum
            );
        }
    }

    function _removeLiquidity(
        CurveLiquidityPool memory info,
        uint256 amount,
        uint256[] memory minimums
    ) internal override {
        if (minimums.length == 2) {
            ICurveTwoCoinPool(info.pool)
                .remove_liquidity(amount, [minimums[0], minimums[1]]);
        } else if (minimums.length == 3) {
            ICurveThreeCoinPool(info.pool)
                .remove_liquidity(
                    amount, [minimums[0], minimums[1], minimums[2]]
                );
        } else {
            ICurveFourCoinPool(info.pool)
                .remove_liquidity(
                    amount, [minimums[0], minimums[1], minimums[2], minimums[3]]
                );
        }
    }
}
