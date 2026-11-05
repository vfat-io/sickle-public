// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { UniswapV3Connector } from
    "contracts/connectors/uniswap/UniswapV3Connector.sol";
import { IUniswapV3Pool } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { NftPoolInfo } from "contracts/structs/NftLiquidityStructs.sol";

interface IOmniClPool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );
}

contract OmniV3Connector is UniswapV3Connector {
    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IOmniClPool(pool).slot0();
        return NftPoolInfo({
            token0: IUniswapV3Pool(pool).token0(),
            token1: IUniswapV3Pool(pool).token1(),
            fee: IUniswapV3Pool(pool).fee(),
            tickSpacing: uint24(IUniswapV3Pool(pool).tickSpacing()),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: IUniswapV3Pool(pool).liquidity(),
            feeGrowthGlobal0X128: IUniswapV3Pool(pool).feeGrowthGlobal0X128(),
            feeGrowthGlobal1X128: IUniswapV3Pool(pool).feeGrowthGlobal1X128()
        });
    }

    function _get_current_tick(
        address pool
    ) internal view override returns (int24 tickCurrent) {
        (, tickCurrent,,,,,) = IOmniClPool(pool).slot0();
    }
}
