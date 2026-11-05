// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    INftLiquidityAmountsResolver
} from "contracts/interfaces/INftLiquidityAmountsResolver.sol";
import {
    LiquidityAmounts
} from "contracts/interfaces/external/uniswap/v3/libraries/LiquidityAmounts.sol";
import {
    TickMath
} from "contracts/interfaces/external/uniswap/v3/libraries/TickMath.sol";

contract NftLiquidityAmountsResolver is INftLiquidityAmountsResolver {
    function amountsForLiquidity(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external pure returns (uint256 amount0, uint256 amount1) {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }
}
