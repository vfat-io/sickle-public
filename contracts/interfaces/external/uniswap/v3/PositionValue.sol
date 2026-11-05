// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import { IUniswapV3Pool } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { FixedPoint128 } from
    "contracts/interfaces/external/uniswap/v3/libraries/FixedPoint128.sol";
import { TickMath } from
    "contracts/interfaces/external/uniswap/v3/libraries/TickMath.sol";
import { LiquidityAmounts } from
    "contracts/interfaces/external/uniswap/v3/libraries/LiquidityAmounts.sol";
import { FullMath } from
    "contracts/interfaces/external/uniswap/v3/libraries/FullMath.sol";

/// @title Returns information about the token value held in a Uniswap V3 NFT
contract PositionValue {
    /// @notice Returns the total amounts of token0 and token1, i.e. the sum of
    /// fees and principal
    /// that a given nonfungible position manager token is worth
    /// @param positionManager The Uniswap V3 NonfungiblePositionManager
    /// @param tokenId The tokenId of the token for which to get the total value
    /// @param sqrtRatioX96 The square root price X96 for which to calculate the
    /// principal amounts
    /// @return amount0 The total amount of token0 including principal and fees
    /// @return amount1 The total amount of token1 including principal and fees
    function total(
        address positionManager,
        address pool,
        uint256 tokenId,
        uint160 sqrtRatioX96
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (uint256 amount0Principal, uint256 amount1Principal) =
            principal(positionManager, tokenId, sqrtRatioX96);
        (uint256 amount0Fee, uint256 amount1Fee) =
            fees(positionManager, pool, tokenId);
        return (amount0Principal + amount0Fee, amount1Principal + amount1Fee);
    }

    /// @notice Calculates the principal (currently acting as liquidity) owed to
    /// the token owner in the event
    /// that the position is burned
    /// @param positionManager The Uniswap V3 NonfungiblePositionManager
    /// @param tokenId The tokenId of the token for which to get the total
    /// principal owed
    /// @param sqrtRatioX96 The square root price X96 for which to calculate the
    /// principal amounts
    /// @return amount0 The principal amount of token0
    /// @return amount1 The principal amount of token1
    function principal(
        address positionManager,
        uint256 tokenId,
        uint160 sqrtRatioX96
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            INonfungiblePositionManager(positionManager).positions(tokenId);

        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }

    /// @notice Calculates the total fees owed to the token owner
    /// @param positionManager The Uniswap V3 NonfungiblePositionManager
    /// @param pool The Uniswap V3 Pool
    /// @param tokenId The tokenId of the token for which to get the total fees
    /// owed
    /// @return amount0 The amount of fees owed in token0
    /// @return amount1 The amount of fees owed in token1
    function fees(
        address positionManager,
        address pool,
        uint256 tokenId
    ) internal view returns (uint256 amount0, uint256 amount1) {
        return _fees(pool, _get_fee_params(positionManager, tokenId));
    }

    struct FeeParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionFeeGrowthInside0LastX128;
        uint256 positionFeeGrowthInside1LastX128;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

    function _get_fee_params(
        address positionManager,
        uint256 tokenId
    ) internal view virtual returns (FeeParams memory) {
        (
            ,
            ,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 positionFeeGrowthInside0LastX128,
            uint256 positionFeeGrowthInside1LastX128,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        ) = INonfungiblePositionManager(positionManager).positions(tokenId);
        return FeeParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            positionFeeGrowthInside0LastX128: positionFeeGrowthInside0LastX128,
            positionFeeGrowthInside1LastX128: positionFeeGrowthInside1LastX128,
            tokensOwed0: tokensOwed0,
            tokensOwed1: tokensOwed1
        });
    }

    function _fees(
        address pool,
        FeeParams memory feeParams
    ) private view returns (uint256 amount0, uint256 amount1) {
        (
            uint256 poolFeeGrowthInside0LastX128,
            uint256 poolFeeGrowthInside1LastX128
        ) = _get_fee_growth_inside(
            pool, feeParams.tickLower, feeParams.tickUpper
        );

        unchecked {
            amount0 = feeParams.tokensOwed0
                + FullMath.mulDiv(
                    poolFeeGrowthInside0LastX128
                        - feeParams.positionFeeGrowthInside0LastX128,
                    feeParams.liquidity,
                    FixedPoint128.Q128
                );

            amount1 = feeParams.tokensOwed1
                + FullMath.mulDiv(
                    poolFeeGrowthInside1LastX128
                        - feeParams.positionFeeGrowthInside1LastX128,
                    feeParams.liquidity,
                    FixedPoint128.Q128
                );
        }
    }

    function _get_fee_growth_outside_tick(
        address pool,
        int24 tick
    )
        internal
        view
        virtual
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        (,, feeGrowthOutside0X128, feeGrowthOutside1X128,,,,) =
            IUniswapV3Pool(pool).ticks(tick);
    }

    function _get_fee_growth_global(
        address pool
    )
        internal
        view
        virtual
        returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128)
    {
        feeGrowthGlobal0X128 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        feeGrowthGlobal1X128 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();
    }

    function _get_current_tick(
        address pool
    ) internal view virtual returns (int24 tickCurrent) {
        (, tickCurrent,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    function _get_fee_growth_inside(
        address pool,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        view
        virtual
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        int24 tickCurrent = _get_current_tick(pool);
        (uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128)
        = _get_fee_growth_outside_tick(pool, tickLower);
        (uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128)
        = _get_fee_growth_outside_tick(pool, tickUpper);

        if (tickCurrent < tickLower) {
            unchecked {
                feeGrowthInside0X128 =
                    lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        } else if (tickCurrent < tickUpper) {
            (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) =
                _get_fee_growth_global(pool);
            unchecked {
                feeGrowthInside0X128 = feeGrowthGlobal0X128
                    - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128
                    - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        } else {
            unchecked {
                feeGrowthInside0X128 =
                    upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            }
        }
    }
}
