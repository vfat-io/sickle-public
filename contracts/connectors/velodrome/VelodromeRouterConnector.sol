// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IRouter } from "contracts/interfaces/external/aerodrome/IRouter.sol";
import { ICLPool } from "contracts/interfaces/external/aerodrome/ICLPool.sol";

import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams,
    SwapParams
} from "contracts/interfaces/ILiquidityConnector.sol";

struct VelodromeLiquidityExtraData {
    bool isStablePool;
}

struct VelodromeSwapExtraData {
    IRouter.Route[] routes;
}

contract VelodromeRouterConnector is ILiquidityConnector {
    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external payable override {
        VelodromeLiquidityExtraData memory _extraData = abi.decode(
            addLiquidityParams.extraData, (VelodromeLiquidityExtraData)
        );
        IRouter(addLiquidityParams.router).addLiquidity(
            addLiquidityParams.tokens[0],
            addLiquidityParams.tokens[1],
            _extraData.isStablePool,
            addLiquidityParams.desiredAmounts[0],
            addLiquidityParams.desiredAmounts[1],
            addLiquidityParams.minAmounts[0],
            addLiquidityParams.minAmounts[1],
            address(this),
            block.timestamp
        );
    }

    function removeLiquidity(
        RemoveLiquidityParams memory removeLiquidityParams
    ) external override {
        VelodromeLiquidityExtraData memory _extraData = abi.decode(
            removeLiquidityParams.extraData, (VelodromeLiquidityExtraData)
        );
        IRouter(removeLiquidityParams.router).removeLiquidity(
            removeLiquidityParams.tokens[0],
            removeLiquidityParams.tokens[1],
            _extraData.isStablePool,
            removeLiquidityParams.lpAmountIn,
            removeLiquidityParams.minAmountsOut[0],
            removeLiquidityParams.minAmountsOut[1],
            address(this),
            block.timestamp
        );
    }

    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external payable virtual override {
        VelodromeSwapExtraData memory _extraData =
            abi.decode(swap.extraData, (VelodromeSwapExtraData));
        IRouter(swap.router).swapExactTokensForTokens(
            swap.amountIn,
            swap.minAmountOut,
            _extraData.routes,
            address(this),
            block.timestamp
        );
    }

    function getPoolPrice(
        address lpToken,
        uint256 baseTokenIndex,
        uint256 // quoteTokenIndex
    ) external view virtual override returns (uint256 price) {
        address token0 = ICLPool(lpToken).token0();
        address token1 = ICLPool(lpToken).token1();

        uint256 amountOut0 = ICLPool(lpToken).getAmountOut(1, token0);
        if (amountOut0 > 0) {
            price = amountOut0 * 1e18;
        } else {
            uint256 amountOut1 = ICLPool(lpToken).getAmountOut(1, token1);
            if (amountOut1 == 0) {
                revert InvalidPrice();
            }
            price = 1e18 / amountOut1;
        }

        if (price == 0) {
            revert InvalidPrice();
        }

        if (baseTokenIndex == 1) {
            price = 1e36 / price;
        }
    }

    function getReserves(
        address lpToken
    ) external view override returns (uint256[] memory reserves) {
        (uint256 reserve0, uint256 reserve1,) = ICLPool(lpToken).getReserves();
        reserves = new uint256[](2);
        reserves[0] = reserve0;
        reserves[1] = reserve1;
    }

    function getTokens(
        address lpToken
    ) external view override returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = ICLPool(lpToken).token0();
        tokens[1] = ICLPool(lpToken).token1();
    }
}
