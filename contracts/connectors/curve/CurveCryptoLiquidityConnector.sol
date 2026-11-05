// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ICurveLiquidityResolver,
    CurveLiquidityPool,
    CurveLiquidityKind
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    ICurveCryptoPool
} from "contracts/interfaces/external/curve/ICurveLiquidityPools.sol";

import {
    CurveFixedLiquidityConnector
} from "./CurveFixedLiquidityConnector.sol";

contract CurveCryptoLiquidityConnector is CurveFixedLiquidityConnector {
    constructor(
        ICurveLiquidityResolver resolver_,
        address weth_
    ) CurveFixedLiquidityConnector(resolver_, weth_) { }

    function poolKind() public pure override returns (CurveLiquidityKind) {
        return CurveLiquidityKind.CryptoFixed;
    }

    function _dy(
        CurveLiquidityPool memory info,
        uint256 i,
        uint256 j,
        uint256 amount
    ) internal view override returns (uint256) {
        return ICurveCryptoPool(info.pool).get_dy(i, j, amount);
    }
}
