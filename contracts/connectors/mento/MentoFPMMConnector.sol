// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IMentoRouter
} from "contracts/interfaces/external/mento/IMentoRouter.sol";
import {
    IFPMM,
    IFPMMFactory
} from "contracts/interfaces/external/mento/IFPMM.sol";
import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/interfaces/ILiquidityConnector.sol";

/// @title MentoFPMMConnector
/// @notice Liquidity connector for Mento v3 FPMM pools through the Mento
/// Router, which is mapped to this connector in the ConnectorRegistry.
/// @dev The router resolves the pool from its `defaultFactory`; the LP token
/// passed by the zap must be that factory's pool for the token pair.
contract MentoFPMMConnector is ILiquidityConnector {
    error InvalidParameters();
    error InvalidPool();

    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external override {
        _validatePool(
            addLiquidityParams.router,
            addLiquidityParams.lpToken,
            addLiquidityParams.tokens
        );
        IMentoRouter(addLiquidityParams.router)
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
        _validatePool(
            removeLiquidityParams.router,
            removeLiquidityParams.lpToken,
            removeLiquidityParams.tokens
        );
        IMentoRouter(removeLiquidityParams.router)
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

    /// @dev FPMM swaps at the oracle rate, not the reserve ratio, so this
    /// returns the oracle quote/base price in whole-token units scaled to
    /// 1e18. Reverts while the oracle rate is invalid, which includes FX
    /// market closure (weekends on EURm/USDm and GBPm/USDm), so exit
    /// triggers cannot fire then. FPMM mint and burn do not read the
    /// oracle, so deposits and withdrawals are unaffected.
    function getPoolPrice(
        address lpToken,
        uint256 baseTokenIndex,
        uint256 quoteTokenIndex
    ) external view override returns (uint256 price) {
        if (
            baseTokenIndex > 1 || quoteTokenIndex > 1
                || baseTokenIndex == quoteTokenIndex
        ) {
            revert InvalidParameters();
        }
        (uint256 numerator, uint256 denominator,,,,,) =
            IFPMM(lpToken).getRebalancingState();
        if (numerator == 0 || denominator == 0) revert InvalidPrice();
        price = baseTokenIndex == 0
            ? Math.mulDiv(numerator, 1e18, denominator)
            : Math.mulDiv(denominator, 1e18, numerator);
        if (price == 0) revert InvalidPrice();
    }

    function getReserves(
        address lpToken
    ) external view override returns (uint256[] memory reserves) {
        (uint256 reserve0, uint256 reserve1,) = IFPMM(lpToken).getReserves();
        reserves = new uint256[](2);
        reserves[0] = reserve0;
        reserves[1] = reserve1;
    }

    function getTokens(
        address lpToken
    ) external view override returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = IFPMM(lpToken).token0();
        tokens[1] = IFPMM(lpToken).token1();
    }

    function _validatePool(
        address router,
        address lpToken,
        address[] memory tokens
    ) internal view {
        if (tokens.length != 2) revert InvalidParameters();
        address factory = IMentoRouter(router).defaultFactory();
        if (
            !IFPMMFactory(factory).isPool(lpToken)
                || IMentoRouter(router).poolFor(tokens[0], tokens[1], factory)
                    != lpToken
        ) {
            revert InvalidPool();
        }
    }
}
