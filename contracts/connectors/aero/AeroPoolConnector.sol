// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SolidlyPoolPrice } from "contracts/libraries/SolidlyPoolPrice.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/interfaces/ILiquidityConnector.sol";
import {
    IAeroPool,
    AERO_V2_STABLE,
    AERO_V2_VOLATILE
} from "contracts/interfaces/external/aero/IAeroPool.sol";

/// @notice Low-level V2 liquidity connector for Aero MetaDEX pools.
/// @dev Callers set both router and lpToken to the pool, and the connector
/// runs the pool's low-level mint/burn sequence directly.
contract AeroPoolConnector is ILiquidityConnector {
    error InvalidParameters();
    error InvalidPoolTokens();
    error InvalidReserves();
    error InsufficientAmount();

    function addLiquidity(
        AddLiquidityParams memory params
    ) external override {
        if (params.desiredAmounts.length != 2 || params.minAmounts.length != 2)
        {
            revert InvalidParameters();
        }
        (
            IAeroPool pool,
            address token0,
            address token1,
            uint256 reserve0,
            uint256 reserve1
        ) = _pool(params.router, params.lpToken, params.tokens);
        (uint256 amount0Desired, uint256 amount1Desired) =
            _poolOrder(token0, params.tokens, params.desiredAmounts);
        (uint256 amount0, uint256 amount1) = _optimalAmounts(
            amount0Desired, amount1Desired, reserve0, reserve1
        );
        (uint256 min0, uint256 min1) =
            _poolOrder(token0, params.tokens, params.minAmounts);
        if (amount0 < min0 || amount1 < min1) {
            revert InsufficientAmount();
        }

        SafeTransferLib.safeTransfer(token0, address(pool), amount0);
        SafeTransferLib.safeTransfer(token1, address(pool), amount1);
        pool.mint(address(this));
    }

    function removeLiquidity(
        RemoveLiquidityParams memory params
    ) external override {
        if (params.lpAmountIn == 0) {
            revert InsufficientAmount();
        }
        if (params.minAmountsOut.length != 2) {
            revert InvalidParameters();
        }
        (IAeroPool pool, address token0,,,) =
            _pool(params.router, params.lpToken, params.tokens);
        // Trading fees accrue separately to LP holders and are not included in
        // burn proceeds. Claim before transferring away the Sickle's LP.
        pool.claimFees(address(this));
        SafeTransferLib.safeTransfer(
            params.lpToken, address(pool), params.lpAmountIn
        );
        (uint256 amount0, uint256 amount1) = pool.burn(address(this));
        (uint256 min0, uint256 min1) =
            _poolOrder(token0, params.tokens, params.minAmountsOut);
        if (amount0 < min0 || amount1 < min1) {
            revert InsufficientAmount();
        }

        // ZapLib approves the router for lpAmountIn. Direct pool burns consume
        // a transfer rather than allowance, so revoke the now-unused approval.
        SafeTransferLib.safeApprove(params.lpToken, params.router, 0);
    }

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
        IAeroPool pool = IAeroPool(lpToken);
        (uint256 dec0, uint256 dec1, uint256 reserve0, uint256 reserve1,,) =
            pool.metadata();
        bytes32 poolType = pool.POOL_TYPE();
        if (poolType != AERO_V2_VOLATILE && poolType != AERO_V2_STABLE) {
            revert InvalidParameters();
        }
        bool stable = poolType == AERO_V2_STABLE;
        return baseTokenIndex == 0
            ? SolidlyPoolPrice.getPrice(reserve0, reserve1, dec0, dec1, stable)
            : SolidlyPoolPrice.getPrice(reserve1, reserve0, dec1, dec0, stable);
    }

    function getReserves(
        address lpToken
    ) external view override returns (uint256[] memory reserves) {
        (uint256 reserve0, uint256 reserve1,) = IAeroPool(lpToken).getReserves();
        reserves = new uint256[](2);
        reserves[0] = reserve0;
        reserves[1] = reserve1;
    }

    function getTokens(
        address lpToken
    ) external view override returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = IAeroPool(lpToken).token0();
        tokens[1] = IAeroPool(lpToken).token1();
    }

    function _pool(
        address router,
        address lpToken,
        address[] memory tokens
    )
        private
        view
        returns (
            IAeroPool pool,
            address token0,
            address token1,
            uint256 reserve0,
            uint256 reserve1
        )
    {
        if (router == address(0) || router != lpToken || tokens.length != 2) {
            revert InvalidParameters();
        }
        pool = IAeroPool(lpToken);
        (,, reserve0, reserve1, token0, token1) = pool.metadata();
        if (!((tokens[0] == token0 && tokens[1] == token1)
                    || (tokens[0] == token1 && tokens[1] == token0))) {
            revert InvalidPoolTokens();
        }
    }

    function _poolOrder(
        address token0,
        address[] memory tokens,
        uint256[] memory amounts
    ) private pure returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = tokens[0] != token0
            ? (amounts[1], amounts[0])
            : (amounts[0], amounts[1]);
    }

    function _optimalAmounts(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 reserve0,
        uint256 reserve1
    ) private pure returns (uint256 amount0, uint256 amount1) {
        if (reserve0 == 0 && reserve1 == 0) {
            if (amount0Desired == 0 || amount1Desired == 0) {
                revert InsufficientAmount();
            }
            return (amount0Desired, amount1Desired);
        }
        if (reserve0 == 0 || reserve1 == 0) {
            revert InvalidReserves();
        }

        uint256 amount1Optimal = Math.mulDiv(amount0Desired, reserve1, reserve0);
        if (amount1Optimal <= amount1Desired) {
            amount0 = amount0Desired;
            amount1 = amount1Optimal;
        } else {
            amount0 = Math.mulDiv(amount1Desired, reserve0, reserve1);
            amount1 = amount1Desired;
        }
        if (amount0 == 0 || amount1 == 0) {
            revert InsufficientAmount();
        }
    }
}
