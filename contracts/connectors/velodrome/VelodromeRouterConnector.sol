// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IRouter } from "contracts/interfaces/external/aerodrome/IRouter.sol";
import { ICLPool } from "contracts/interfaces/external/aerodrome/ICLPool.sol";

import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/interfaces/ILiquidityConnector.sol";

import { SolidlyPoolPrice } from "contracts/libraries/SolidlyPoolPrice.sol";

struct VelodromeLiquidityExtraData {
    bool isStablePool;
}

contract VelodromeRouterConnector is ILiquidityConnector {
    error InvalidParameters();

    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external override {
        VelodromeLiquidityExtraData memory _extraData = abi.decode(
            addLiquidityParams.extraData, (VelodromeLiquidityExtraData)
        );
        IRouter(addLiquidityParams.router)
            .addLiquidity(
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
        IRouter(removeLiquidityParams.router)
            .removeLiquidity(
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

    /// @dev Raw quote/base units, scaled to 1e18. Stable prices use the
    /// marginal invariant slope, rather than a fee-bearing swap quote.
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
        return baseTokenIndex == 0
            ? SolidlyPoolPrice.getPrice(
                reserve0, reserve1, unit0, unit1, stable
            )
            : SolidlyPoolPrice.getPrice(
                    reserve1, reserve0, unit1, unit0, stable
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
