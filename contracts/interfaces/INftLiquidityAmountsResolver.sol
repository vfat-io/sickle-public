// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface INftLiquidityAmountsResolver {
    function amountsForLiquidity(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external pure returns (uint256 amount0, uint256 amount1);
}
