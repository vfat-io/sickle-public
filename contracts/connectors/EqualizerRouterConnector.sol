// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ILiquidityConnector,
    AddLiquidityData,
    RemoveLiquidityData,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";
import { IEqualizerRouter } from
    "contracts/interfaces/external/equalizer/IEqualizerRouter.sol";

struct EqualizerLiquidityExtraData {
    bool isStablePool;
}

struct EqualizerSwapExtraData {
    IEqualizerRouter.Route[] routes;
}

contract EqualizerRouterConnector is ILiquidityConnector {
    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        EqualizerLiquidityExtraData memory _extraData = abi.decode(
            addLiquidityData.extraData, (EqualizerLiquidityExtraData)
        );
        IEqualizerRouter(addLiquidityData.router).addLiquidity(
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
        EqualizerLiquidityExtraData memory _extraData = abi.decode(
            removeLiquidityData.extraData, (EqualizerLiquidityExtraData)
        );
        IEqualizerRouter(removeLiquidityData.router).removeLiquidity(
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
        EqualizerSwapExtraData memory _extraData =
            abi.decode(swapData.extraData, (EqualizerSwapExtraData));
        IEqualizerRouter(swapData.router).swapExactTokensForTokens(
            swapData.amountIn,
            swapData.minAmountOut,
            _extraData.routes,
            address(this),
            block.timestamp
        );
    }
}
