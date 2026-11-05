// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import {
    ICurveLiquidityResolver,
    CurveLiquidityPool,
    CurveLiquidityKind
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import { ICurvePool } from "contracts/interfaces/external/curve/ICurvePool.sol";
import {
    CurveFixedLiquidityConnector
} from "./CurveFixedLiquidityConnector.sol";

contract CurveStableLiquidityConnector is CurveFixedLiquidityConnector {
    constructor(
        ICurveLiquidityResolver resolver_,
        address weth_
    ) CurveFixedLiquidityConnector(resolver_, weth_) { }

    function poolKind() public pure override returns (CurveLiquidityKind) {
        return CurveLiquidityKind.StableFixed;
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
