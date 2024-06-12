// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ILiquidityConnector,
    AddLiquidityData,
    RemoveLiquidityData,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";
import { IRouter } from "contracts/interfaces/external/aerodrome/IRouter.sol";

struct AerodromeLiquidityExtraData {
    bool isStablePool;
}

struct AerodromeSwapExtraData {
    IRouter.Route[] routes;
}

contract AerodromeRouterConnector is ILiquidityConnector {
    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        AerodromeLiquidityExtraData memory _extraData = abi.decode(
            addLiquidityData.extraData, (AerodromeLiquidityExtraData)
        );
        IRouter(addLiquidityData.router).addLiquidity(
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
        AerodromeLiquidityExtraData memory _extraData = abi.decode(
            removeLiquidityData.extraData, (AerodromeLiquidityExtraData)
        );
        IRouter(removeLiquidityData.router).removeLiquidity(
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
        AerodromeSwapExtraData memory _extraData =
            abi.decode(swapData.extraData, (AerodromeSwapExtraData));
        IRouter(swapData.router).swapExactTokensForTokens(
            swapData.amountIn,
            swapData.minAmountOut,
            _extraData.routes,
            address(this),
            block.timestamp
        );
    }
}
