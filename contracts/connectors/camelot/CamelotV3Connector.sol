// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { FenixV3Connector } from
    "contracts/connectors/fenix/FenixV3Connector.sol";
import {
    NftPoolInfo,
    NftPoolKey
} from "contracts/connectors/uniswap/UniswapV3Connector.sol";
import { IAlgebraPool } from
    "contracts/interfaces/external/algebra/IAlgebraPool.sol";
import { IAlgebraNonfungiblePositionManager } from
    "contracts/interfaces/external/algebra/IAlgebraNonfungiblePositionManager.sol";
import {
    ICamelotNftPool,
    ICamelotV3Factory
} from "contracts/interfaces/external/camelot/ICamelotInterfaces.sol";

contract CamelotV3Connector is FenixV3Connector {
    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick,, uint16 fee_,,,,) =
            ICamelotNftPool(pool).globalState();
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

    function fee(
        address pool,
        uint256 // tokenId
    ) external view virtual override returns (uint24) {
        (,, uint16 fee_,,,,,) = ICamelotNftPool(pool).globalState();
        return uint24(fee_);
    }

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view virtual override returns (NftPoolKey memory) {
        (,, address token0, address token1,,,,,,,) =
            IAlgebraNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPoolKey({
            poolAddress: ICamelotV3Factory(poolFactory).poolByPair(token0, token1),
            poolId: bytes32(0) // Uniswap V4 only
         });
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
            ICamelotNftPool(pool).ticks(tick_);
    }

    function _get_current_tick(
        address pool
    ) internal view virtual override returns (int24 tickCurrent) {
        (, tickCurrent,,,,,,) = ICamelotNftPool(pool).globalState();
    }
}
