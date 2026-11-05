// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ILiquidityConnector
} from "contracts/interfaces/ILiquidityConnector.sol";

/// @dev Fee-free marginal quote/base price, scaled to 1e18 in reserve units.
library SolidlyPoolPrice {
    function getPrice(
        uint256 reserveBase,
        uint256 reserveQuote,
        uint256 unitBase,
        uint256 unitQuote,
        bool stable
    ) internal pure returns (uint256 price) {
        if (reserveBase == 0 || reserveQuote == 0) {
            revert ILiquidityConnector.InvalidPrice();
        }
        uint256 factor = 1e18;
        if (stable) {
            if (unitBase == 0 || unitQuote == 0) {
                revert ILiquidityConnector.InvalidPrice();
            }
            factor = _stableFactor(
                Math.mulDiv(reserveBase, 1e18, unitBase),
                Math.mulDiv(reserveQuote, 1e18, unitQuote)
            );
        }
        price = Math.mulDiv(reserveQuote, factor, reserveBase);
        if (price == 0) revert ILiquidityConnector.InvalidPrice();
    }

    // For k = x^3*y + x*y^3, marginal price is
    // (y/x) * (3x^2 + y^2) / (x^2 + 3y^2). x and y are normalised
    // reserves. Evaluating the factor on min/max bounds all intermediates.
    function _stableFactor(
        uint256 x,
        uint256 y
    ) private pure returns (uint256) {
        if (x == 0 || y == 0) revert ILiquidityConnector.InvalidPrice();
        if (x >= y) {
            uint256 t2 = _squareOfRatio(y, x);
            return Math.mulDiv(3e18 + t2, 1e18, 1e18 + 3 * t2);
        }
        uint256 s2 = _squareOfRatio(x, y);
        return Math.mulDiv(1e18 + 3 * s2, 1e18, 3e18 + s2);
    }

    function _squareOfRatio(
        uint256 numerator,
        uint256 denominator
    ) private pure returns (uint256) {
        uint256 ratio = Math.mulDiv(numerator, 1e18, denominator);
        return Math.mulDiv(ratio, ratio, 1e18);
    }
}
