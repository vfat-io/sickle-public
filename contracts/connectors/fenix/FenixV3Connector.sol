// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    UniswapV3Connector,
    NftAddLiquidity,
    NftPoolInfo,
    NftPoolKey
} from "contracts/connectors/uniswap/UniswapV3Connector.sol";
import { IAlgebraPool } from
    "contracts/interfaces/external/algebra/IAlgebraPool.sol";
import { IAlgebraNonfungiblePositionManager } from
    "contracts/interfaces/external/algebra/IAlgebraNonfungiblePositionManager.sol";
import { IAlgebraFactory } from
    "contracts/interfaces/external/algebra/IAlgebraFactory.sol";

struct FenixV3SwapExtraData {
    address pool;
    bytes path;
}

contract FenixV3Connector is UniswapV3Connector {
    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal virtual override {
        IAlgebraNonfungiblePositionManager.MintParams memory params =
        IAlgebraNonfungiblePositionManager.MintParams({
            token0: addLiquidityParams.pool.token0,
            token1: addLiquidityParams.pool.token1,
            tickLower: addLiquidityParams.tickLower,
            tickUpper: addLiquidityParams.tickUpper,
            amount0Desired: addLiquidityParams.amount0Desired,
            amount1Desired: addLiquidityParams.amount1Desired,
            amount0Min: addLiquidityParams.amount0Min,
            amount1Min: addLiquidityParams.amount1Min,
            recipient: address(this),
            deadline: block.timestamp
        });

        IAlgebraNonfungiblePositionManager(address(addLiquidityParams.nft)).mint(
            params
        );
    }

    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick, uint16 fee_,,,) =
            IAlgebraPool(pool).globalState();
        return NftPoolInfo({
            token0: IAlgebraPool(pool).token0(),
            token1: IAlgebraPool(pool).token1(),
            fee: fee_,
            tickSpacing: uint24(IAlgebraPool(pool).tickSpacing()),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: IAlgebraPool(pool).liquidity(),
            feeGrowthGlobal0X128: IAlgebraPool(pool).totalFeeGrowth0Token(),
            feeGrowthGlobal1X128: IAlgebraPool(pool).totalFeeGrowth1Token()
        });
    }

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view virtual override returns (NftPoolKey memory) {
        (,, address token0, address token1,,,,,,,) =
            IAlgebraNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPoolKey({
            poolAddress: IAlgebraFactory(poolFactory).computePoolAddress(
                token0, token1
            ),
            poolId: bytes32(0) // Uniswap V4 only
         });
    }

    function positionLiquidity(
        address nftManager,
        uint256 tokenId
    )
        public
        view
        virtual
        override
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        (,,,, tickLower, tickUpper, liquidity,,,,) =
            IAlgebraNonfungiblePositionManager(nftManager).positions(tokenId);
    }

    function _get_fee_growth_outside_tick(
        address pool,
        int24 tick
    )
        internal
        view
        virtual
        override
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        (,,,, feeGrowthOutside0X128, feeGrowthOutside1X128) =
            IAlgebraPool(pool).ticks(tick);
    }

    function _get_fee_growth_global(
        address pool
    )
        internal
        view
        virtual
        override
        returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128)
    {
        feeGrowthGlobal0X128 = IAlgebraPool(pool).totalFeeGrowth0Token();
        feeGrowthGlobal1X128 = IAlgebraPool(pool).totalFeeGrowth1Token();
    }

    function _get_current_tick(
        address pool
    ) internal view virtual override returns (int24 tickCurrent) {
        (, tickCurrent,,,,) = IAlgebraPool(pool).globalState();
    }

    function _get_fee_params(
        address positionManager,
        uint256 tokenId
    ) internal view virtual override returns (FeeParams memory) {
        (
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
        ) = IAlgebraNonfungiblePositionManager(positionManager).positions(
            tokenId
        );
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
}
