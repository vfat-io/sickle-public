// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapParams } from "contracts/structs/LiquidityStructs.sol";
import {
    INftFarmConnector,
    Farm,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import { ISwapRouter } from
    "contracts/interfaces/external/uniswap/ISwapRouter.sol";
import {
    UniswapV3Connector,
    NftAddLiquidity,
    NftRemoveLiquidity,
    NftPositionInfo,
    NftPoolInfo,
    NftPoolKey,
    NftPosition
} from "contracts/connectors/UniswapV3Connector.sol";
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
    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external payable override {
        FenixV3SwapExtraData memory extraData =
            abi.decode(swap.extraData, (FenixV3SwapExtraData));

        IERC20(swap.tokenIn).approve(extraData.pool, swap.amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
            path: extraData.path,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: swap.amountIn,
            amountOutMinimum: swap.minAmountOut
        });

        ISwapRouter(swap.router).exactInput(params);
    }

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
        (,,,, feeGrowthOutside0X128, feeGrowthOutside1X128) =
            IAlgebraPool(pool).ticks(tick_);
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

    function positionInfo(
        address nftManager,
        uint256 tokenId
    ) public view virtual override returns (NftPositionInfo memory) {
        (,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            IAlgebraNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPositionInfo({
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
    }
}
