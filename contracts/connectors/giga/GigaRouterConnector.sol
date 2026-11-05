// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IGigaRouter
} from "contracts/interfaces/external/giga/IGigaRouter.sol";
import { ICLPool } from "contracts/interfaces/external/aerodrome/ICLPool.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SolidlyPoolPrice } from "contracts/libraries/SolidlyPoolPrice.sol";
import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/interfaces/ILiquidityConnector.sol";

struct VelodromeLiquidityExtraData {
    bool isStablePool;
}

contract GigaRouterConnector is ILiquidityConnector {
    error InvalidParameters();

    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external override {
        VelodromeLiquidityExtraData memory _extraData = abi.decode(
            addLiquidityParams.extraData, (VelodromeLiquidityExtraData)
        );

        IGigaRouter(addLiquidityParams.router)
            .addLiquidity(
                IGigaRouter.AddLiquidityParams({
                tokenA: addLiquidityParams.tokens[0],
                tokenB: addLiquidityParams.tokens[1],
                stable: _extraData.isStablePool,
                amountADesired: addLiquidityParams.desiredAmounts[0],
                amountBDesired: addLiquidityParams.desiredAmounts[1],
                amountAMin: addLiquidityParams.minAmounts[0],
                amountBMin: addLiquidityParams.minAmounts[1],
                to: address(this),
                deadline: block.timestamp
            })
            );
    }

    function removeLiquidity(
        RemoveLiquidityParams memory removeLiquidityParams
    ) external override {
        VelodromeLiquidityExtraData memory _extraData = abi.decode(
            removeLiquidityParams.extraData, (VelodromeLiquidityExtraData)
        );
        IGigaRouter(removeLiquidityParams.router)
            .removeLiquidity(
                IGigaRouter.RemoveLiquidityParams({
                tokenA: removeLiquidityParams.tokens[0],
                tokenB: removeLiquidityParams.tokens[1],
                stable: _extraData.isStablePool,
                liquidity: removeLiquidityParams.lpAmountIn,
                amountAMin: removeLiquidityParams.minAmountsOut[0],
                amountBMin: removeLiquidityParams.minAmountsOut[1],
                to: address(this),
                deadline: block.timestamp
            })
            );
    }

    /// @dev Preserve Giga's whole quote/base token price scaled to 1e18.
    function getPoolPrice(
        address lpToken,
        uint256 baseTokenIndex,
        uint256 quoteTokenIndex
    ) external view virtual override returns (uint256 price) {
        if (
            baseTokenIndex > 1 || quoteTokenIndex > 1
                || baseTokenIndex == quoteTokenIndex
        ) {
            revert InvalidParameters();
        }
        (
            uint256 unit0,
            uint256 unit1,
            uint256 reserve0,
            uint256 reserve1,
            bool stable,,
        ) = ICLPool(lpToken).metadata();
        if (unit0 == 0 || unit1 == 0) revert InvalidPrice();
        uint256 normalized0 = Math.mulDiv(reserve0, 1e18, unit0);
        uint256 normalized1 = Math.mulDiv(reserve1, 1e18, unit1);
        return baseTokenIndex == 0
            ? SolidlyPoolPrice.getPrice(
                normalized0, normalized1, 1e18, 1e18, stable
            )
            : SolidlyPoolPrice.getPrice(
                normalized1, normalized0, 1e18, 1e18, stable
            );
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
