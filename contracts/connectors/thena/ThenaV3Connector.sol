// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IThenaV3Pool } from
    "contracts/interfaces/external/thena/IThenaV3Pool.sol";
import { IThenaAlgebraFactory } from
    "contracts/interfaces/external/thena/IThenaAlgebraFactory.sol";
import { IAlgebraNonfungiblePositionManager } from
    "contracts/interfaces/external/algebra/IAlgebraNonfungiblePositionManager.sol";

import { FenixV3Connector } from
    "contracts/connectors/fenix/FenixV3Connector.sol";
import {
    NftPositionInfo,
    NftPoolInfo,
    NftPoolKey
} from "contracts/interfaces/INftLiquidityConnector.sol";

contract ThenaV3Connector is FenixV3Connector {
    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick, uint16 fee_,,,,) =
            IThenaV3Pool(pool).globalState();
        return NftPoolInfo({
            token0: IThenaV3Pool(pool).token0(),
            token1: IThenaV3Pool(pool).token1(),
            fee: fee_,
            tickSpacing: uint24(IThenaV3Pool(pool).tickSpacing()),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: IThenaV3Pool(pool).liquidity(),
            feeGrowthGlobal0X128: IThenaV3Pool(pool).totalFeeGrowth0Token(),
            feeGrowthGlobal1X128: IThenaV3Pool(pool).totalFeeGrowth1Token()
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
            poolAddress: IThenaAlgebraFactory(poolFactory).poolByPair(
                token0, token1
            ),
            poolId: bytes32(0) // Uniswap V4 only
         });
    }

    function fee(
        address pool,
        uint256 // tokenId
    ) external view virtual override returns (uint24) {
        (,,, uint16 fee_,,,) = IThenaV3Pool(pool).globalState();
        return uint24(fee_);
    }

    function feeGrowthOutside(
        address pool,
        bytes32, // poolId
        int24 tick_
    )
        external
        view
        virtual
        override
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        (,, feeGrowthOutside0X128, feeGrowthOutside1X128,,,,) =
            IThenaV3Pool(pool).ticks(tick_);
    }
}
