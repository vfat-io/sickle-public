// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from
    "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/interfaces/ILiquidityConnector.sol";

/// @title PassthroughLiquidityConnector
/// @notice Single-token no-op liquidity connector.
/// @dev Used when ZapLib needs a valid addLiquidity/removeLiquidity router
/// target, but the "LP token" is already the final asset that the farm
/// connector consumes directly (for example KAT before KatanaVaultConnector
/// deposits it into the avKAT vault).
contract PassthroughLiquidityConnector is ILiquidityConnector {
    error InvalidPassthroughConfig();

    uint256 internal constant ONE = 1e18;

    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external pure override {
        _validateAdd(addLiquidityParams);
    }

    function removeLiquidity(
        RemoveLiquidityParams memory removeLiquidityParams
    ) external pure override {
        _validateRemove(removeLiquidityParams);
    }

    function getPoolPrice(
        address,
        uint256 baseTokenIndex,
        uint256 quoteTokenIndex
    ) external pure override returns (uint256) {
        if (baseTokenIndex != 0 || quoteTokenIndex != 0) {
            revert InvalidPrice();
        }
        return ONE;
    }

    function getReserves(
        address lpToken
    ) external view override returns (uint256[] memory reserves) {
        reserves = new uint256[](1);
        reserves[0] = IERC20(lpToken).balanceOf(address(this));
    }

    function getTokens(
        address lpToken
    ) external pure override returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = lpToken;
    }

    function _validateAdd(
        AddLiquidityParams memory addLiquidityParams
    ) internal pure {
        if (
            addLiquidityParams.lpToken == address(0)
                || addLiquidityParams.tokens.length != 1
                || addLiquidityParams.desiredAmounts.length != 1
                || addLiquidityParams.minAmounts.length != 1
                || addLiquidityParams.tokens[0] != addLiquidityParams.lpToken
        ) {
            revert InvalidPassthroughConfig();
        }
    }

    function _validateRemove(
        RemoveLiquidityParams memory removeLiquidityParams
    ) internal pure {
        if (
            removeLiquidityParams.lpToken == address(0)
                || removeLiquidityParams.tokens.length != 1
                || removeLiquidityParams.minAmountsOut.length != 1
                || removeLiquidityParams.tokens[0]
                    != removeLiquidityParams.lpToken
        ) {
            revert InvalidPassthroughConfig();
        }
    }
}
