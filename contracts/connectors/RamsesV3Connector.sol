// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ILiquidityConnector.sol";
import "../interfaces/IFarmConnector.sol";
import "../interfaces/external/ramses/IRamsesNonfungiblePositionManager.sol";
import "../interfaces/external/uniswap/ISwapRouter.sol";

struct NewPositionParams {
    int24 tickLower;
    int24 tickUpper;
    uint24 fee;
}

struct RamsesV3AddLiquidityExtraData {
    uint256 tokenId;
    bool isIncrease;
    NewPositionParams newPositionParams;
}

struct RamsesV3RemoveLiquidityExtraData {
    uint256 tokenId;
    uint128 liquidity;
    uint128 amount0Max;
    uint128 amount1Max;
}

struct RamsesV3SwapExtraData {
    address pool;
    bytes path;
}

struct RamsesV3ClaimExtraData {
    uint256 tokenId;
    address[] tokens;
    uint128 maxAmount0;
    uint128 maxAmount1;
}

contract RamsesV3Connector is ILiquidityConnector, IFarmConnector {
    constructor() { }

    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        RamsesV3AddLiquidityExtraData memory extra = abi.decode(
            addLiquidityData.extraData, (RamsesV3AddLiquidityExtraData)
        );

        if (extra.isIncrease) {
            IRamsesNonfungiblePositionManager.IncreaseLiquidityParams memory
                params = IRamsesNonfungiblePositionManager
                    .IncreaseLiquidityParams({
                    tokenId: extra.tokenId,
                    amount0Desired: addLiquidityData.desiredAmounts[0],
                    amount1Desired: addLiquidityData.desiredAmounts[1],
                    amount0Min: addLiquidityData.minAmounts[0],
                    amount1Min: addLiquidityData.minAmounts[1],
                    deadline: block.timestamp + 1
                });

            IRamsesNonfungiblePositionManager(addLiquidityData.router)
                .increaseLiquidity(params);
        } else {
            IRamsesNonfungiblePositionManager.MintParams memory params =
            IRamsesNonfungiblePositionManager.MintParams({
                token0: addLiquidityData.tokens[0],
                token1: addLiquidityData.tokens[1],
                fee: extra.newPositionParams.fee,
                tickLower: extra.newPositionParams.tickLower,
                tickUpper: extra.newPositionParams.tickUpper,
                amount0Desired: addLiquidityData.desiredAmounts[0],
                amount1Desired: addLiquidityData.desiredAmounts[1],
                amount0Min: addLiquidityData.minAmounts[0],
                amount1Min: addLiquidityData.minAmounts[1],
                recipient: address(this),
                deadline: block.timestamp + 1,
                veRamTokenId: 0
            });

            IRamsesNonfungiblePositionManager(addLiquidityData.router).mint(
                params
            );
        }
    }

    function removeLiquidity(RemoveLiquidityData memory removeLiquidityData)
        external
        override
    {
        RamsesV3RemoveLiquidityExtraData memory extra = abi.decode(
            removeLiquidityData.extraData, (RamsesV3RemoveLiquidityExtraData)
        );

        if (extra.liquidity == type(uint128).max) {
            (,,,,,,, uint128 liquidity,,,,) = IRamsesNonfungiblePositionManager(
                removeLiquidityData.router
            ).positions(extra.tokenId);
            extra.liquidity = liquidity;
        }

        IRamsesNonfungiblePositionManager.DecreaseLiquidityParams memory params =
        IRamsesNonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: extra.tokenId,
            liquidity: extra.liquidity,
            amount0Min: removeLiquidityData.minAmountsOut[0],
            amount1Min: removeLiquidityData.minAmountsOut[1],
            deadline: block.timestamp + 1
        });

        IRamsesNonfungiblePositionManager(removeLiquidityData.router)
            .decreaseLiquidity(params);

        IRamsesNonfungiblePositionManager(removeLiquidityData.router).collect(
            IRamsesNonfungiblePositionManager.CollectParams({
                tokenId: extra.tokenId,
                recipient: address(this),
                amount0Max: extra.amount0Max,
                amount1Max: extra.amount1Max
            })
        );

        (,,,,,,, uint128 liquidityAfter,,,,) = IRamsesNonfungiblePositionManager(
            removeLiquidityData.router
        ).positions(extra.tokenId);

        if (liquidityAfter == 0) {
            IRamsesNonfungiblePositionManager(removeLiquidityData.router).burn(
                extra.tokenId
            );
        }
    }

    function swapExactTokensForTokens(SwapData memory swapData)
        external
        payable
        override
    {
        RamsesV3SwapExtraData memory extraData =
            abi.decode(swapData.extraData, (RamsesV3SwapExtraData));

        IERC20(swapData.tokenIn).approve(extraData.pool, swapData.amountIn);

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

    function deposit(
        address target,
        address token,
        bytes memory extraData
    ) external payable override { }

    function withdraw(
        address target,
        uint256 amount,
        bytes memory extraData
    ) external override { }

    function claim(address target, bytes memory extraData) external override {
        RamsesV3ClaimExtraData memory data =
            abi.decode(extraData, (RamsesV3ClaimExtraData));
        IRamsesNonfungiblePositionManager(target).getReward(
            data.tokenId, data.tokens
        );
        if (data.maxAmount0 > 0 || data.maxAmount1 > 0) {
            IRamsesNonfungiblePositionManager.CollectParams memory params =
            IRamsesNonfungiblePositionManager.CollectParams({
                tokenId: data.tokenId,
                recipient: address(this),
                amount0Max: data.maxAmount0,
                amount1Max: data.maxAmount1
            });
            IRamsesNonfungiblePositionManager(target).collect(params);
        }
    }
}
