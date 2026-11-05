// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IUniswapV3Pool
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {
    IAlgebraFactory
} from "contracts/interfaces/external/algebra/IAlgebraFactory.sol";
import {
    TickMath
} from "contracts/interfaces/external/uniswap/v3/libraries/TickMath.sol";

/// @title AlgebraPoolAdapter
/// @notice Per-DEX adapter for `DexType.AlgebraPool`.
/// @dev `SwapRouter` is `msg.sender` to `pool.swap` (via `adapterCall`),
/// so the pool calls back into `SwapRouter`'s existing
/// `algebraSwapCallback`, which handles the factory + custom-deployer
/// allowlist check and the payment from `SwapRouter`'s balance. Like
/// the V3 adapter, we *also* run the equivalent pre-call validation
/// here to preserve the legacy invariant that direct pool calls only
/// target factory-derived pools, even if a malicious "pool" never
/// calls back. dexData encodes `(address pool)` for standard pools or
/// `(address pool, address customDeployer)` for custom Algebra pools.
contract AlgebraPoolAdapter is DexAdapterBase {
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

        address customDeployer;
        if (step.dexData.length >= 64) {
            (, customDeployer) = abi.decode(step.dexData, (address, address));
        }

        bool zeroForOne = _validatePoolAndDirection(
            pool, step.tokenIn, step.tokenOut, customDeployer
        );

        bytes memory callbackData =
            abi.encode(step.tokenIn, msg.sender, customDeployer);

        // See UniswapV3PoolAdapter.
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
                    callbackData
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

    /// @dev Mirrors the legacy `_validateAlgebraPoolAndDirection` on
    /// `SwapRouter`. Authorises the factory via the allowlist, then
    /// proves `pool` is deployed by that factory for the declared token
    /// pair (or via a registered custom deployer for non-standard
    /// Algebra Integral pools).
    function _validatePoolAndDirection(
        address pool,
        address tokenIn,
        address tokenOut,
        address customDeployer
    ) internal view returns (bool zeroForOne) {
        (address token0, address token1, address factory) =
            _readPoolTokensAndFactory(pool);

        allowlist.requireAllowedFactory(factory);
        if (
            !_isAlgebraPoolFromFactory(
                factory, token0, token1, pool, customDeployer
            )
        ) {
            revert InvalidPool();
        }

        if (tokenIn == token0 && tokenOut == token1) return true;
        if (tokenIn == token1 && tokenOut == token0) return false;
        revert InvalidTokenIn();
    }

    function _readPoolTokensAndFactory(
        address pool
    ) internal view returns (address token0, address token1, address factory) {
        IUniswapV3Pool algebraPool = IUniswapV3Pool(pool);
        token0 = algebraPool.token0();
        token1 = algebraPool.token1();
        factory = algebraPool.factory();
    }

    function _isAlgebraPoolFromFactory(
        address factory,
        address token0,
        address token1,
        address pool,
        address customDeployer
    ) internal view returns (bool) {
        (bool ok, address expected) = _tryPoolByPair(factory, token0, token1);
        if (ok) {
            if (expected == pool) return true;
            if (expected != address(0) && customDeployer == address(0)) {
                return false;
            }
        }

        if (customDeployer != address(0)) {
            allowlist.requireAllowedCustomDeployer(factory, customDeployer);
            (ok, expected) =
                _tryCustomPoolByPair(factory, customDeployer, token0, token1);
            if (ok && expected == pool) return true;
        }
        return false;
    }

    function _tryPoolByPair(
        address factory,
        address token0,
        address token1
    ) internal view returns (bool, address) {
        (bool success, bytes memory data) = factory.staticcall(
            abi.encodeWithSelector(
                IAlgebraFactory.poolByPair.selector, token0, token1
            )
        );
        if (!success || data.length < 32) return (false, address(0));
        return (true, abi.decode(data, (address)));
    }

    function _tryCustomPoolByPair(
        address factory,
        address deployer,
        address token0,
        address token1
    ) internal view returns (bool, address) {
        (bool success, bytes memory data) = factory.staticcall(
            abi.encodeWithSelector(
                IAlgebraFactory.customPoolByPair.selector,
                deployer,
                token0,
                token1
            )
        );
        if (!success || data.length < 32) return (false, address(0));
        return (true, abi.decode(data, (address)));
    }
}
