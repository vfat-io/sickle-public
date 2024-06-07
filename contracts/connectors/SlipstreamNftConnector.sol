// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/ILiquidityConnector.sol";
import
    "../interfaces/external/aerodrome/ISlipstreamNonfungiblePositionManager.sol";

struct SlipstreamAddLiquidityExtraData {
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    int24 tickSpacing;
}

struct SlipstreamRemoveLiquidityExtraData {
    uint256 tokenId;
    uint128 liquidity;
    uint128 amount0Max;
    uint128 amount1Max;
}

contract SlipstreamNftConnector is ILiquidityConnector {
    constructor() { }

    error Unsupported();

    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        SlipstreamAddLiquidityExtraData memory extra = abi.decode(
            addLiquidityData.extraData, (SlipstreamAddLiquidityExtraData)
        );

        if (extra.tokenId == 0) {
            ISlipstreamNonfungiblePositionManager.MintParams memory params =
            ISlipstreamNonfungiblePositionManager.MintParams({
                token0: addLiquidityData.tokens[0],
                token1: addLiquidityData.tokens[1],
                tickSpacing: extra.tickSpacing,
                tickLower: extra.tickLower,
                tickUpper: extra.tickUpper,
                amount0Desired: addLiquidityData.desiredAmounts[0],
                amount1Desired: addLiquidityData.desiredAmounts[1],
                amount0Min: addLiquidityData.minAmounts[0],
                amount1Min: addLiquidityData.minAmounts[1],
                recipient: address(this),
                deadline: block.timestamp + 1,
                sqrtPriceX96: 0
            });

            ISlipstreamNonfungiblePositionManager(addLiquidityData.router).mint(
                params
            );
        } else {
            ISlipstreamNonfungiblePositionManager.IncreaseLiquidityParams memory
                params = ISlipstreamNonfungiblePositionManager
                    .IncreaseLiquidityParams({
                    tokenId: extra.tokenId,
                    amount0Desired: addLiquidityData.desiredAmounts[0],
                    amount1Desired: addLiquidityData.desiredAmounts[1],
                    amount0Min: addLiquidityData.minAmounts[0],
                    amount1Min: addLiquidityData.minAmounts[1],
                    deadline: block.timestamp + 1
                });

            ISlipstreamNonfungiblePositionManager(addLiquidityData.router)
                .increaseLiquidity(params);
        }
    }

    function removeLiquidity(RemoveLiquidityData memory removeLiquidityData)
        external
        override
    {
        SlipstreamRemoveLiquidityExtraData memory extra = abi.decode(
            removeLiquidityData.extraData, (SlipstreamRemoveLiquidityExtraData)
        );

        ISlipstreamNonfungiblePositionManager.DecreaseLiquidityParams memory
            params = ISlipstreamNonfungiblePositionManager
                .DecreaseLiquidityParams({
                tokenId: extra.tokenId,
                liquidity: extra.liquidity,
                amount0Min: removeLiquidityData.minAmountsOut[0],
                amount1Min: removeLiquidityData.minAmountsOut[1],
                deadline: block.timestamp + 1
            });

        ISlipstreamNonfungiblePositionManager(removeLiquidityData.router)
            .decreaseLiquidity(params);

        ISlipstreamNonfungiblePositionManager(removeLiquidityData.router)
            .collect(
            ISlipstreamNonfungiblePositionManager.CollectParams({
                tokenId: extra.tokenId,
                recipient: address(this),
                amount0Max: extra.amount0Max,
                amount1Max: extra.amount1Max
            })
        );

        (,,,,,,, uint128 liquidity,,,,) = ISlipstreamNonfungiblePositionManager(
            removeLiquidityData.router
        ).positions(extra.tokenId);
        if (liquidity == 0) {
            ISlipstreamNonfungiblePositionManager(removeLiquidityData.router)
                .burn(extra.tokenId);
        }
    }

    function swapExactTokensForTokens(SwapData memory)
        external
        payable
        override
    {
        revert Unsupported();
    }
}
