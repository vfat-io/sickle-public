// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CurveLiquidityConnector } from "./CurveLiquidityConnector.sol";
import {
    ICurveLiquidityResolver,
    CurveLiquidityPool,
    CurveLiquidityKind
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    ICurveTwoCoinLendingPool,
    ICurveThreeCoinLendingPool,
    ICurveFourCoinLendingPool,
    ICurveLendingPool
} from "contracts/interfaces/external/curve/ICurveLiquidityPools.sol";

/// @notice Aave-style stable pools take underlying assets with the explicit
/// use_underlying ABI. The native registry authenticates the ordered assets.
contract CurveLendingLiquidityConnector is CurveLiquidityConnector {
    constructor(
        ICurveLiquidityResolver resolver_,
        address weth_
    ) CurveLiquidityConnector(resolver_, weth_) { }

    function poolKind() public pure override returns (CurveLiquidityKind) {
        return CurveLiquidityKind.StableLending;
    }

    function _coins(
        CurveLiquidityPool memory info
    ) internal view override returns (address[8] memory) {
        return
            resolver.metaRegistryForPool(info.pool)
                .get_underlying_coins(info.pool);
    }

    function _balances(
        CurveLiquidityPool memory info
    ) internal view override returns (uint256[8] memory) {
        return resolver.metaRegistryForPool(info.pool)
            .get_underlying_balances(info.pool);
    }

    function _addLiquidity(
        CurveLiquidityPool memory info,
        uint256[] memory amounts,
        uint256 minimum,
        uint256 value
    ) internal override {
        if (value != 0) revert InvalidLiquidityParams();
        if (amounts.length == 2) {
            ICurveTwoCoinLendingPool(info.pool)
                .add_liquidity([amounts[0], amounts[1]], minimum, true);
        } else if (amounts.length == 3) {
            ICurveThreeCoinLendingPool(info.pool)
                .add_liquidity(
                    [amounts[0], amounts[1], amounts[2]], minimum, true
                );
        } else {
            ICurveFourCoinLendingPool(info.pool)
                .add_liquidity(
                    [amounts[0], amounts[1], amounts[2], amounts[3]],
                    minimum,
                    true
                );
        }
    }

    function _removeLiquidity(
        CurveLiquidityPool memory info,
        uint256 amount,
        uint256[] memory minimums
    ) internal override {
        if (minimums.length == 2) {
            ICurveTwoCoinLendingPool(info.pool)
                .remove_liquidity(amount, [minimums[0], minimums[1]], true);
        } else if (minimums.length == 3) {
            ICurveThreeCoinLendingPool(info.pool)
                .remove_liquidity(
                    amount, [minimums[0], minimums[1], minimums[2]], true
                );
        } else {
            ICurveFourCoinLendingPool(info.pool)
                .remove_liquidity(
                    amount,
                    [minimums[0], minimums[1], minimums[2], minimums[3]],
                    true
                );
        }
    }

    function _dy(
        CurveLiquidityPool memory info,
        uint256 i,
        uint256 j,
        uint256 amount
    ) internal view override returns (uint256) {
        return ICurveLendingPool(info.pool)
            .get_dy_underlying(int128(int256(i)), int128(int256(j)), amount);
    }
}
