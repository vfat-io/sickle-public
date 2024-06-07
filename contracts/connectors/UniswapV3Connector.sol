// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ILiquidityConnector.sol";
import "../interfaces/external/uniswap/INonfungiblePositionManager.sol";
import "../interfaces/external/uniswap/ISwapRouter.sol";

struct UniswapV3AddLiquidityExtraData {
    int24 tickLower;
    int24 tickUpper;
    uint24 fee;
}

struct UniswapV3RemoveLiquidityExtraData {
    uint256 tokenId;
    uint128 amount0Max;
    uint128 amount1Max;
}

struct UniswapV3SwapExtraData {
    address pool;
    bytes path;
}

contract UniswapV3Connector is ILiquidityConnector {
    constructor() { }

    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        UniswapV3AddLiquidityExtraData memory extra = abi.decode(
            addLiquidityData.extraData, (UniswapV3AddLiquidityExtraData)
        );

        INonfungiblePositionManager.MintParams memory params =
        INonfungiblePositionManager.MintParams({
            token0: addLiquidityData.tokens[0],
            token1: addLiquidityData.tokens[1],
            fee: extra.fee,
            tickLower: extra.tickLower,
            tickUpper: extra.tickUpper,
            amount0Desired: addLiquidityData.desiredAmounts[0],
            amount1Desired: addLiquidityData.desiredAmounts[1],
            amount0Min: addLiquidityData.minAmounts[0],
            amount1Min: addLiquidityData.minAmounts[1],
            recipient: address(this),
            deadline: block.timestamp + 1
        });

        //(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
        // =
        INonfungiblePositionManager(addLiquidityData.router).mint(params);
    }

    function removeLiquidity(RemoveLiquidityData memory removeLiquidityData)
        external
        override
    {
        UniswapV3RemoveLiquidityExtraData memory extra = abi.decode(
            removeLiquidityData.extraData, (UniswapV3RemoveLiquidityExtraData)
        );

        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(
            removeLiquidityData.router
        ).positions(extra.tokenId);
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
        INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: extra.tokenId,
            liquidity: liquidity,
            amount0Min: removeLiquidityData.minAmountsOut[0],
            amount1Min: removeLiquidityData.minAmountsOut[1],
            deadline: block.timestamp + 1
        });

        INonfungiblePositionManager(removeLiquidityData.router)
            .decreaseLiquidity(params);

        INonfungiblePositionManager(removeLiquidityData.router).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: extra.tokenId,
                recipient: address(this),
                amount0Max: extra.amount0Max,
                amount1Max: extra.amount1Max
            })
        );

        INonfungiblePositionManager(removeLiquidityData.router).burn(
            extra.tokenId
        );
    }

    function swapExactTokensForTokens(SwapData memory swapData)
        external
        payable
        override
    {
        UniswapV3SwapExtraData memory extraData =
            abi.decode(swapData.extraData, (UniswapV3SwapExtraData));

        IERC20(swapData.tokenIn).approve(
            address(extraData.pool), swapData.amountIn
        );

        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
            path: extraData.path,
            recipient: address(this),
            deadline: block.timestamp + 1,
            amountIn: swapData.amountIn,
            amountOutMinimum: swapData.minAmountOut
        });

        ISwapRouter(swapData.router).exactInput(params);
    }
}
