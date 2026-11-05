// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ICurveMetaRegistry,
    ICurveLiquidityResolver,
    CurveLiquidityPool,
    CurveLiquidityKind
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";

struct CurveHandlerConfig {
    address handler;
    CurveLiquidityKind kind;
}

interface ICurveGaugePoolFactory {
    function get_gauge(
        address pool
    ) external view returns (address);
    function get_token(
        address pool
    ) external view returns (address);
}

interface ICurveLpToken {
    function minter() external view returns (address);
}

interface ICurveLpRegistry {
    function get_pool_from_lp_token(
        address token
    ) external view returns (address);
}

/// @notice Resolves a Curve pool or separate LP to its pool, LP, coin count and
/// liquidity ABI family.
/// @dev Curve's registries authenticate bindings; handler kinds select the ABI.
/// Unknown handlers fail closed. No pool or LP allowlist is stored.
contract CurveLiquidityResolver is ICurveLiquidityResolver {
    error UnsupportedPool(address target);
    error InvalidHandler();

    ICurveMetaRegistry public immutable override metaRegistry;
    mapping(address => CurveLiquidityKind) public handlerKind;
    ICurveMetaRegistry[] private metaRegistries;
    address[] private gaugeSources;

    constructor(
        ICurveMetaRegistry[] memory metaRegistries_,
        CurveHandlerConfig[] memory handlers
    ) {
        if (metaRegistries_.length == 0) revert InvalidHandler();
        metaRegistry = metaRegistries_[0];
        for (uint256 i; i < metaRegistries_.length; i++) {
            if (address(metaRegistries_[i]).code.length == 0) {
                revert InvalidHandler();
            }
            for (uint256 j; j < i; j++) {
                if (metaRegistries_[i] == metaRegistries_[j]) {
                    revert InvalidHandler();
                }
            }
            metaRegistries.push(metaRegistries_[i]);
        }
        for (uint256 i; i < handlers.length; i++) {
            CurveHandlerConfig memory config = handlers[i];
            if (
                config.handler == address(0)
                    || config.kind == CurveLiquidityKind.Unsupported
                    || handlerKind[config.handler]
                        != CurveLiquidityKind.Unsupported
            ) revert InvalidHandler();
            handlerKind[config.handler] = config.kind;
            address source = metaRegistry.get_base_registry(config.handler);
            if (source == address(0)) revert InvalidHandler();
            gaugeSources.push(source);
        }
    }

    /// @notice Accepts registered pools and LPs authenticated by Curve.
    function poolInfo(
        address target
    ) external view override returns (CurveLiquidityPool memory info) {
        if (target == address(0)) revert UnsupportedPool(target);
        ICurveMetaRegistry source = _poolRegistry(target);
        if (address(source) != address(0)) {
            info.pool = target;
            info.lpToken = source.get_lp_token(target);
        } else {
            info.pool = _poolFromLp(target);
            info.lpToken = target;
            source = _poolRegistry(info.pool);
        }
        if (address(source) == address(0)) revert UnsupportedPool(target);
        address[10] memory handlers =
            source.get_registry_handlers_from_pool(info.pool);
        info.kind = handlerKind[handlers[0]];
        // The main stable registry also contains legacy crypto pools.
        if (
            (info.kind == CurveLiquidityKind.StableFixed
                    || info.kind == CurveLiquidityKind.StableLending)
                && source.get_pool_asset_type(info.pool) == 4
        ) info.kind = CurveLiquidityKind.CryptoFixed;
        info.nCoins = source.get_n_coins(info.pool);
        if (
            info.kind == CurveLiquidityKind.Unsupported || info.nCoins < 2
                || info.nCoins > 8
        ) revert UnsupportedPool(target);
        if (
            info.kind == CurveLiquidityKind.StableNg
                && source.is_meta(info.pool)
        ) {
            if (info.nCoins != 2) revert UnsupportedPool(target);
            info.kind = CurveLiquidityKind.StableFixed;
        }
        if (info.kind == CurveLiquidityKind.StableLending) {
            // Only registry families configured for the Aave lending ABI use
            // underlying coins. Plain pools and metapools retain direct coins.
            address[8] memory coins = source.get_coins(info.pool);
            address[8] memory underlying =
                source.get_underlying_coins(info.pool);
            if (
                source.is_meta(info.pool)
                    || keccak256(abi.encode(coins))
                        == keccak256(abi.encode(underlying))
            ) {
                info.kind = CurveLiquidityKind.StableFixed;
            }
        }
        if (
            (info.kind == CurveLiquidityKind.StableFixed && info.nCoins > 4)
                || (info.kind == CurveLiquidityKind.StableLending
                    && info.nCoins > 4)
                || (info.kind == CurveLiquidityKind.CryptoFixed
                    && info.nCoins > 3)
        ) revert UnsupportedPool(target);
    }

    /// @notice Native factory mappings authenticate custody independently of
    /// subsequent MetaRegistry handler or current-gauge changes.
    function isFactoryGauge(
        address gauge,
        address lp
    ) external view override returns (bool) {
        if (gauge == address(0) || lp == address(0)) return false;
        address pool =
            _readAddress(lp, abi.encodeCall(ICurveLpToken.minter, ()), 50_000);
        for (uint256 i; i < gaugeSources.length; i++) {
            address source = gaugeSources[i];
            if (
                _readAddress(
                        source,
                        abi.encodeCall(ICurveGaugePoolFactory.get_gauge, (lp)),
                        50_000
                    ) == gauge
            ) return true;
            if (
                pool != address(0)
                    && _readAddress(
                            source,
                            abi.encodeCall(
                                ICurveGaugePoolFactory.get_token, (pool)
                            ),
                            50_000
                        ) == lp
                    && _readAddress(
                            source,
                            abi.encodeCall(
                                ICurveGaugePoolFactory.get_gauge, (pool)
                            ),
                            50_000
                        ) == gauge
            ) return true;
        }
        return false;
    }

    function metaRegistryForPool(
        address pool
    ) external view override returns (ICurveMetaRegistry source) {
        source = _poolRegistry(pool);
        if (address(source) == address(0)) revert UnsupportedPool(pool);
    }

    function _poolRegistry(
        address pool
    ) private view returns (ICurveMetaRegistry) {
        if (pool == address(0)) return ICurveMetaRegistry(address(0));
        for (uint256 i; i < metaRegistries.length; i++) {
            ICurveMetaRegistry source = metaRegistries[i];
            try source.get_lp_token(pool) returns (address lp) {
                if (lp == address(0)) continue;
                try source.get_registry_handlers_from_pool(pool) returns (
                    address[10] memory handlers
                ) {
                    if (
                        handlerKind[handlers[0]]
                            != CurveLiquidityKind.Unsupported
                    ) {
                        return source;
                    }
                } catch { }
            } catch { }
        }
        return ICurveMetaRegistry(address(0));
    }

    function _poolFromLp(
        address token
    ) internal view returns (address) {
        address hint = _readAddress(
            token, abi.encodeCall(ICurveLpToken.minter, ()), 50_000
        );
        if (_matchesLp(hint, token)) return hint;
        for (uint256 i; i < gaugeSources.length; i++) {
            address pool = _readAddress(
                gaugeSources[i],
                abi.encodeCall(
                    ICurveLpRegistry.get_pool_from_lp_token, (token)
                ),
                gasleft()
            );
            if (_matchesLp(pool, token)) return pool;
        }
        return address(0);
    }

    function _readAddress(
        address target,
        bytes memory data,
        uint256 gasLimit
    ) internal view returns (address) {
        (bool success, bytes memory result) =
            target.staticcall{ gas: gasLimit }(data);
        if (!success || result.length != 32) return address(0);
        uint256 value = abi.decode(result, (uint256));
        return value <= type(uint160).max ? address(uint160(value)) : address(0);
    }

    function _matchesLp(
        address pool,
        address token
    ) internal view returns (bool) {
        if (pool == address(0)) return false;
        ICurveMetaRegistry source = _poolRegistry(pool);
        if (address(source) == address(0)) return false;
        return source.get_lp_token(pool) == token;
    }
}
