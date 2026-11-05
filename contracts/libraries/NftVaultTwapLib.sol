// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IUniswapV3Pool
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {
    INftLiquidityAmountsResolver
} from "contracts/interfaces/INftLiquidityAmountsResolver.sol";
import {
    TickMath
} from "contracts/interfaces/external/uniswap/v3/libraries/TickMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library NftVaultTwapLib {
    error PriceMoved();

    /// @notice Values a vault's holdings (its Uniswap V3 position plus idle
    /// token0/token1 balances) in token1 terms at the pool's `twapWindow` TWAP
    /// price. Idle balances are included so a rebalance that legitimately parks
    /// value as vault dust (to be reinvested) is not mistaken for a loss; the
    /// floor only catches NET value leaving the vault. Using the (swap-invariant)
    /// TWAP price — not the in-tx spot — lets a caller compare value before and
    /// after a rebalance that moves the pool, so spot manipulation during the
    /// rebalance cannot inflate the measured post-rebalance value.
    function vaultValueInToken1(
        INftLiquidityAmountsResolver resolver,
        address pool,
        uint32 twapWindow,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 idle0,
        uint256 idle1
    ) external view returns (uint256 valueInToken1) {
        uint160 sqrtPriceX96 =
            TickMath.getSqrtRatioAtTick(twapTick_(pool, twapWindow));
        (uint256 amount0, uint256 amount1) = resolver.amountsForLiquidity(
            sqrtPriceX96, tickLower, tickUpper, liquidity
        );
        amount0 += idle0;
        amount1 += idle1;
        // value(token1) = amount1 + amount0 * (sqrtPriceX96 / 2**96)**2
        uint256 amount0InToken1 = Math.mulDiv(
            Math.mulDiv(amount0, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96
        );
        valueInToken1 = amount1 + amount0InToken1;
    }

    /// @notice Values the vault (position + idle balances) in token0 OR token1
    /// terms at the TWAP, selected by `inToken0`.
    function vaultValue(
        INftLiquidityAmountsResolver resolver,
        address pool,
        uint32 twapWindow,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 idle0,
        uint256 idle1,
        bool inToken0
    ) external view returns (uint256 value) {
        uint160 sqrtPriceX96 =
            TickMath.getSqrtRatioAtTick(twapTick_(pool, twapWindow));
        (uint256 amount0, uint256 amount1) = resolver.amountsForLiquidity(
            sqrtPriceX96, tickLower, tickUpper, liquidity
        );
        amount0 += idle0;
        amount1 += idle1;
        if (inToken0) {
            // value(token0) = amount0 + amount1 * (2**96 / sqrtPriceX96)**2
            value = amount0
                + Math.mulDiv(
                    Math.mulDiv(amount1, 1 << 96, sqrtPriceX96),
                    1 << 96,
                    sqrtPriceX96
                );
        } else {
            // value(token1) = amount1 + amount0 * (sqrtPriceX96 / 2**96)**2
            value = amount1
                + Math.mulDiv(
                    Math.mulDiv(amount0, sqrtPriceX96, 1 << 96),
                    sqrtPriceX96,
                    1 << 96
                );
        }
    }

    /// @notice Computes the arithmetic mean tick of `pool` over `twapWindow`
    /// seconds and reverts with PriceMoved if the deviation between
    /// `currentTick` and the TWAP tick exceeds `maxTickDeviation`.
    function checkTwap(
        address pool,
        uint32 twapWindow,
        uint24 maxTickDeviation,
        int24 currentTick
    ) external view {
        int24 twapTick = twapTick_(pool, twapWindow);
        uint24 deviation = currentTick > twapTick
            ? uint24(currentTick - twapTick)
            : uint24(twapTick - currentTick);
        if (deviation > maxTickDeviation) revert PriceMoved();
    }

    function twapTick_(
        address pool,
        uint32 twapWindow
    ) internal view returns (int24 arithmeticMeanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) =
            IUniswapV3Pool(pool).observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int56 window = int56(uint56(twapWindow));
        arithmeticMeanTick = int24(tickCumulativesDelta / window);
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % window != 0)) {
            arithmeticMeanTick--;
        }
    }
}
