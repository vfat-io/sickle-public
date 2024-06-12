// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ILiquidityConnector,
    AddLiquidityData,
    RemoveLiquidityData,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";
import { IUniswapV2Router02 } from
    "contracts/interfaces/external/uniswap/IUniswapV2Router02.sol";

struct UniswapV2SwapExtraData {
    address[] path;
}

contract UniswapV2Connector is ILiquidityConnector {
    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        IUniswapV2Router02(addLiquidityData.router).addLiquidity(
            addLiquidityData.tokens[0],
            addLiquidityData.tokens[1],
            addLiquidityData.desiredAmounts[0],
            addLiquidityData.desiredAmounts[1],
            addLiquidityData.minAmounts[0],
            addLiquidityData.minAmounts[1],
            address(this),
            block.timestamp
        );
    }

    function removeLiquidity(RemoveLiquidityData memory removeLiquidityData)
        external
        override
    {
        IUniswapV2Router02(removeLiquidityData.router).removeLiquidity(
            removeLiquidityData.tokens[0],
            removeLiquidityData.tokens[1],
            removeLiquidityData.lpAmountIn,
            removeLiquidityData.minAmountsOut[0],
            removeLiquidityData.minAmountsOut[1],
            address(this),
            block.timestamp
        );
    }

    function swapExactTokensForTokens(SwapData memory swapData)
        external
        payable
        override
    {
        UniswapV2SwapExtraData memory extraData =
            abi.decode(swapData.extraData, (UniswapV2SwapExtraData));

        IUniswapV2Router02(swapData.router).swapExactTokensForTokens(
            swapData.amountIn,
            swapData.minAmountOut,
            extraData.path,
            address(this),
            block.timestamp
        );
    }
}
