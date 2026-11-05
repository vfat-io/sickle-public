// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IUniswapV2Router02
} from "contracts/interfaces/external/uniswap/IUniswapV2Router02.sol";
import {
    IUniswapV2Pair
} from "contracts/interfaces/external/uniswap/IUniswapV2Pair.sol";

import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/interfaces/ILiquidityConnector.sol";

import { SolidlyPoolPrice } from "contracts/libraries/SolidlyPoolPrice.sol";

struct UniswapV2SwapExtraData {
    address[] path;
}

contract UniswapV2Connector is ILiquidityConnector {
    error InvalidParameters();

    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external override {
        IUniswapV2Router02(addLiquidityParams.router)
            .addLiquidity(
                addLiquidityParams.tokens[0],
                addLiquidityParams.tokens[1],
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
        IUniswapV2Router02(removeLiquidityParams.router)
            .removeLiquidity(
                removeLiquidityParams.tokens[0],
                removeLiquidityParams.tokens[1],
                removeLiquidityParams.lpAmountIn,
                removeLiquidityParams.minAmountsOut[0],
                removeLiquidityParams.minAmountsOut[1],
                address(this),
                block.timestamp
            );
    }

    function getPoolPrice(
        address lpToken,
        uint256 baseTokenIndex,
        uint256 quoteTokenIndex
    ) external view returns (uint256) {
        if (
            baseTokenIndex > 1 || quoteTokenIndex > 1
                || baseTokenIndex == quoteTokenIndex
        ) {
            revert InvalidParameters();
        }
        (uint256 reserve0, uint256 reserve1,) =
            IUniswapV2Pair(lpToken).getReserves();
        return baseTokenIndex == 0
            ? SolidlyPoolPrice.getPrice(reserve0, reserve1, 1, 1, false)
            : SolidlyPoolPrice.getPrice(reserve1, reserve0, 1, 1, false);
    }

    function getReserves(
        address lpToken
    ) external view returns (uint256[] memory reserves) {
        (uint256 reserve0, uint256 reserve1,) =
            IUniswapV2Pair(lpToken).getReserves();
        reserves = new uint256[](2);
        reserves[0] = reserve0;
        reserves[1] = reserve1;
    }

    function getTokens(
        address lpToken
    ) external view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = IUniswapV2Pair(lpToken).token0();
        tokens[1] = IUniswapV2Pair(lpToken).token1();
    }
}
