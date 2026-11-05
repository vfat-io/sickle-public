// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    NftPoolInfo,
    NftPoolKey
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { FenixV3Connector } from
    "contracts/connectors/fenix/FenixV3Connector.sol";
import { IQuickswapV3Pool } from
    "contracts/interfaces/external/quickswap/IQuickswapV3Pool.sol";
import { IAlgebraNonfungiblePositionManager } from
    "contracts/interfaces/external/algebra/IAlgebraNonfungiblePositionManager.sol";
import { IAlgebraFactory } from
    "contracts/interfaces/external/algebra/IAlgebraFactory.sol";

contract QuickswapV3Connector is FenixV3Connector {
    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick, uint16 fee_,,,,) =
            IQuickswapV3Pool(pool).globalState();
        return NftPoolInfo({
            token0: IQuickswapV3Pool(pool).token0(),
            token1: IQuickswapV3Pool(pool).token1(),
            fee: fee_,
            tickSpacing: uint24(IQuickswapV3Pool(pool).tickSpacing()),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: IQuickswapV3Pool(pool).liquidity(),
            feeGrowthGlobal0X128: IQuickswapV3Pool(pool).totalFeeGrowth0Token(),
            feeGrowthGlobal1X128: IQuickswapV3Pool(pool).totalFeeGrowth1Token()
        });
    }

    function fee(
        address pool,
        uint256 // tokenId
    ) external view virtual override returns (uint24) {
        (,,, uint16 fee_,,,) = IQuickswapV3Pool(pool).globalState();
        return uint24(fee_);
    }

    function _get_fee_growth_outside_tick(
        address pool,
        int24 tick_
    )
        internal
        view
        virtual
        override
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        (,, feeGrowthOutside0X128, feeGrowthOutside1X128,,,,) =
            IQuickswapV3Pool(pool).ticks(tick_);
    }

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view virtual override returns (NftPoolKey memory) {
        (,, address token0, address token1,,,,,,,) =
            IAlgebraNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPoolKey({
            poolAddress: IAlgebraFactory(poolFactory).poolByPair(token0, token1),
            poolId: bytes32(0) // Uniswap V4 only
         });
    }

    function _get_current_tick(
        address pool
    ) internal view virtual override returns (int24 tickCurrent) {
        (, tickCurrent,,,,,) = IQuickswapV3Pool(pool).globalState();
    }
}
