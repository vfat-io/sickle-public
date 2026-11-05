// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { UniswapV3Connector } from
    "contracts/connectors/uniswap/UniswapV3Connector.sol";
import { NftPoolInfo } from "contracts/interfaces/INftLiquidityConnector.sol";
import { IPancakeV3Pool } from
    "contracts/interfaces/external/pancake/IPancakeV3Pool.sol";

contract PancakeV3Connector is UniswapV3Connector {
    error Unsupported();

    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IPancakeV3Pool(pool).slot0();
        return NftPoolInfo({
            token0: IPancakeV3Pool(pool).token0(),
            token1: IPancakeV3Pool(pool).token1(),
            fee: IPancakeV3Pool(pool).fee(),
            tickSpacing: uint24(IPancakeV3Pool(pool).tickSpacing()),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: IPancakeV3Pool(pool).liquidity(),
            feeGrowthGlobal0X128: IPancakeV3Pool(pool).feeGrowthGlobal0X128(),
            feeGrowthGlobal1X128: IPancakeV3Pool(pool).feeGrowthGlobal1X128()
        });
    }

    function _get_current_tick(
        address pool
    ) internal view virtual override returns (int24 tickCurrent) {
        (, tickCurrent,,,,,) = IPancakeV3Pool(pool).slot0();
    }
}
