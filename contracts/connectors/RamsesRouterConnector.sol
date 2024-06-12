// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ILiquidityConnector,
    AddLiquidityData,
    RemoveLiquidityData,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";
import { IRamsesRouter } from
    "contracts/interfaces/external/ramses/IRamsesRouter.sol";

struct RamsesLiquidityExtraData {
    bool isStablePool;
}

struct RamsesSwapExtraData {
    IRamsesRouter.Route[] routes;
}

contract RamsesRouterConnector is ILiquidityConnector {
    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        RamsesLiquidityExtraData memory _extraData =
            abi.decode(addLiquidityData.extraData, (RamsesLiquidityExtraData));
        IRamsesRouter(addLiquidityData.router).addLiquidity(
            addLiquidityData.tokens[0],
            addLiquidityData.tokens[1],
            _extraData.isStablePool,
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
        RamsesLiquidityExtraData memory _extraData = abi.decode(
            removeLiquidityData.extraData, (RamsesLiquidityExtraData)
        );
        IRamsesRouter(removeLiquidityData.router).removeLiquidity(
            removeLiquidityData.tokens[0],
            removeLiquidityData.tokens[1],
            _extraData.isStablePool,
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
        RamsesSwapExtraData memory _extraData =
            abi.decode(swapData.extraData, (RamsesSwapExtraData));
        IRamsesRouter(swapData.router).swapExactTokensForTokens(
            swapData.amountIn,
            swapData.minAmountOut,
            _extraData.routes,
            address(this),
            block.timestamp
        );
    }
}
