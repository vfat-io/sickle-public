// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CurveLiquidityConnector } from "./CurveLiquidityConnector.sol";
import {
    ICurveLiquidityResolver,
    CurveLiquidityPool,
    CurveLiquidityKind
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    ICurveDynamicArrayPool
} from "contracts/interfaces/external/curve/ICurveLiquidityPools.sol";
import { ICurvePool } from "contracts/interfaces/external/curve/ICurvePool.sol";

contract CurveStableNgLiquidityConnector is CurveLiquidityConnector {
    constructor(
        ICurveLiquidityResolver resolver_,
        address weth_
    ) CurveLiquidityConnector(resolver_, weth_) { }

    function poolKind() public pure override returns (CurveLiquidityKind) {
        return CurveLiquidityKind.StableNg;
    }

    function _addLiquidity(
        CurveLiquidityPool memory info,
        uint256[] memory amounts,
        uint256 minimum,
        uint256 value
    ) internal override {
        ICurveDynamicArrayPool(info.pool).add_liquidity{ value: value }(
            amounts, minimum
        );
    }

    function _removeLiquidity(
        CurveLiquidityPool memory info,
        uint256 amount,
        uint256[] memory minimums
    ) internal override {
        ICurveDynamicArrayPool(info.pool).remove_liquidity(amount, minimums);
    }

    function _dy(
        CurveLiquidityPool memory info,
        uint256 i,
        uint256 j,
        uint256 amount
    ) internal view override returns (uint256) {
        return ICurvePool(info.pool)
            .get_dy(int128(uint128(i)), int128(uint128(j)), amount);
    }
}
