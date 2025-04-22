// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    INftLiquidityConnector,
    NftAddLiquidity,
    NftRemoveLiquidity,
    SwapParams,
    NftPositionInfo,
    NftPoolInfo,
    NftPoolKey
} from "contracts/interfaces/INftLiquidityConnector.sol";
import
    "contracts/interfaces/external/aerodrome/ISlipstreamNonfungiblePositionManager.sol";
import { UniswapV3Connector } from "contracts/connectors/UniswapV3Connector.sol";
import { IUniswapV3Pool } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { ICLPool } from "contracts/interfaces/external/aerodrome/ICLPool.sol";
import { ICLPoolFactory } from
    "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";

struct SlipstreamAddLiquidityExtraData {
    int24 tickSpacing;
}

contract SlipstreamNftConnector is UniswapV3Connector {
    error Unsupported();

    function swapExactTokensForTokens(
        SwapParams memory
    ) external payable override {
        revert Unsupported();
    }

    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal override {
        SlipstreamAddLiquidityExtraData memory extra = abi.decode(
            addLiquidityParams.extraData, (SlipstreamAddLiquidityExtraData)
        );

        ISlipstreamNonfungiblePositionManager.MintParams memory params =
        ISlipstreamNonfungiblePositionManager.MintParams({
            token0: addLiquidityParams.pool.token0,
            token1: addLiquidityParams.pool.token1,
            tickSpacing: extra.tickSpacing,
            tickLower: addLiquidityParams.tickLower,
            tickUpper: addLiquidityParams.tickUpper,
            amount0Desired: addLiquidityParams.amount0Desired,
            amount1Desired: addLiquidityParams.amount1Desired,
            amount0Min: addLiquidityParams.amount0Min,
            amount1Min: addLiquidityParams.amount1Min,
            recipient: address(this),
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });

        ISlipstreamNonfungiblePositionManager(address(addLiquidityParams.nft))
            .mint(params);
    }

    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick,,,,) = ICLPool(pool).slot0();
        return NftPoolInfo({
            token0: ICLPool(pool).token0(),
            token1: ICLPool(pool).token1(),
            fee: ICLPool(pool).fee(),
            tickSpacing: uint24(ICLPool(pool).tickSpacing()),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: ICLPool(pool).liquidity(),
            feeGrowthGlobal0X128: ICLPool(pool).feeGrowthGlobal0X128(),
            feeGrowthGlobal1X128: ICLPool(pool).feeGrowthGlobal1X128()
        });
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
        (,,, feeGrowthOutside0X128, feeGrowthOutside1X128,,,,,) =
            ICLPool(pool).ticks(tick_);
    }

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view override returns (NftPoolKey memory) {
        (,, address token0, address token1, int24 tickSpacing,,,,,,,) =
            ISlipstreamNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPoolKey({
            poolAddress: ICLPoolFactory(poolFactory).getPool(
                token0, token1, tickSpacing
            ),
            poolId: bytes32(0) // Uniswap V4 only
         });
    }

    function positionInfo(
        address nftManager,
        uint256 tokenId
    ) public view virtual override returns (NftPositionInfo memory) {
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            ISlipstreamNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPositionInfo({
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
    }
}
