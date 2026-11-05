// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IUniswapV3Pool,
    IUniswapV3PoolImmutables
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {
    IUniswapV3Factory
} from "contracts/interfaces/external/uniswap/IUniswapV3Factory.sol";
import {
    ISlipstreamFactory
} from "contracts/interfaces/external/aerodrome/ISlipstreamFactory.sol";
import {
    TickMath
} from "contracts/interfaces/external/uniswap/v3/libraries/TickMath.sol";

/// @title UniswapV3PoolAdapter
/// @notice Per-DEX adapter for `DexType.UniswapV3Pool` — direct Uniswap
/// V3 (or Slipstream) pool swap.
/// @dev `SwapRouter` is `msg.sender` to `pool.swap` (via `adapterCall`),
/// so the pool calls back into `SwapRouter`'s existing
/// `uniswapV3SwapCallback`, which handles the factory check and the
/// payment from `SwapRouter`'s balance. The callback alone is not
/// sufficient though — a malicious "pool" might not call back at all
/// and would still get arbitrary code execution. To preserve the
/// invariant *"pool.swap is only invoked against factory-validated
/// pools"*, the adapter runs the factory + pool-derivation check
/// before issuing the `adapterCall`.
contract UniswapV3PoolAdapter is DexAdapterBase {
    error InvalidPool();
    error InvalidTokenIn();
    error PartialFill();

    constructor(
        address admin_,
        address allowlist_
    ) DexAdapterBase(admin_, allowlist_) { }

    function version() external pure override returns (uint16) {
        return 1;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        address pool = _decodePoolAddress(step);
        if (pool == address(0)) revert InvalidAddress();

        bool zeroForOne =
            _validatePoolAndDirection(pool, step.tokenIn, step.tokenOut);

        // Arm SwapRouter's callback to expect a payment of exactly `amountIn`
        // of `step.tokenIn` from `pool`. Without this, the V3 callback refuses
        // to pay.
        _armPoolCallback(pool, step.tokenIn, amountIn);

        bytes memory ret = _adapterCall(
            pool,
            0,
            abi.encodeCall(
                IUniswapV3Pool.swap,
                (
                    msg.sender,
                    zeroForOne,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    int256(amountIn),
                    zeroForOne
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1,
                    abi.encode(msg.sender)
                )
            )
        );

        (int256 amount0, int256 amount1) = abi.decode(ret, (int256, int256));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountConsumed =
            zeroForOne ? uint256(amount0) : uint256(amount1);
        if (amountConsumed != amountIn) revert PartialFill();
        return 0;
    }

    /// @dev Mirrors the legacy `_validateV3PoolAndDirection` on
    /// `SwapRouter`. Authorises the factory via the allowlist, then
    /// proves `pool` is actually deployed by that factory for the
    /// declared token pair (either via the V3 `getPool(token0,token1,fee)`
    /// lookup or the Slipstream `getPool(token0,token1,tickSpacing)`
    /// lookup). The callback handler on `SwapRouter` re-runs an
    /// equivalent check, but doing it here keeps the invariant
    /// "pool.swap targets only factory-derived pools" intact even when a
    /// hostile address would otherwise skip the callback.
    function _validatePoolAndDirection(
        address pool,
        address tokenIn,
        address tokenOut
    ) internal view returns (bool zeroForOne) {
        IUniswapV3Pool v3pool = IUniswapV3Pool(pool);
        address token0 = v3pool.token0();
        address token1 = v3pool.token1();
        address factory = v3pool.factory();

        allowlist.requireAllowedFactory(factory);
        (uint24 fee, int24 tickSpacing) = _readFeeAndTickSpacing(pool);
        if (
            !_isPoolFromFactory(factory, token0, token1, fee, tickSpacing, pool)
        ) {
            revert InvalidPool();
        }

        if (tokenIn == token0 && tokenOut == token1) return true;
        if (tokenIn == token1 && tokenOut == token0) return false;
        revert InvalidTokenIn();
    }

    function _readFeeAndTickSpacing(
        address pool
    ) internal view returns (uint24 fee, int24 tickSpacing) {
        (bool ok, bytes memory data) = pool.staticcall(
            abi.encodeWithSelector(IUniswapV3PoolImmutables.fee.selector)
        );
        if (ok && data.length >= 32) {
            fee = abi.decode(data, (uint24));
        }
        (ok, data) = pool.staticcall(
            abi.encodeWithSelector(IUniswapV3PoolImmutables.tickSpacing.selector)
        );
        if (ok && data.length >= 32) {
            tickSpacing = abi.decode(data, (int24));
        }
    }

    function _isPoolFromFactory(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        address pool
    ) internal view returns (bool) {
        (bool ok, bytes memory data) = factory.staticcall(
            abi.encodeWithSelector(
                IUniswapV3Factory.getPool.selector, token0, token1, fee
            )
        );
        if (ok && data.length >= 32 && abi.decode(data, (address)) == pool) {
            return true;
        }
        (ok, data) = factory.staticcall(
            abi.encodeWithSelector(
                ISlipstreamFactory.getPool.selector, token0, token1, tickSpacing
            )
        );
        if (ok && data.length >= 32 && abi.decode(data, (address)) == pool) {
            return true;
        }
        return false;
    }
}
