// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ICurveMetaRegistry {
    function get_gauge(
        address pool
    ) external view returns (address);
    function get_base_registry(
        address handler
    ) external view returns (address);
    function get_pool_from_lp_token(
        address token
    ) external view returns (address);
    function get_lp_token(
        address pool
    ) external view returns (address);
    function get_registry_handlers_from_pool(
        address pool
    ) external view returns (address[10] memory);
    function get_n_coins(
        address pool
    ) external view returns (uint256);
    function get_pool_asset_type(
        address pool
    ) external view returns (uint256);
    function get_coins(
        address pool
    ) external view returns (address[8] memory);
    function get_balances(
        address pool
    ) external view returns (uint256[8] memory);
    function get_underlying_coins(
        address pool
    ) external view returns (address[8] memory);
    function get_underlying_balances(
        address pool
    ) external view returns (uint256[8] memory);
    function is_meta(
        address pool
    ) external view returns (bool);
}

enum CurveLiquidityKind {
    Unsupported,
    StableFixed,
    StableNg,
    CryptoFixed,
    StableLending
}

struct CurveLiquidityPool {
    address pool;
    address lpToken;
    uint256 nCoins;
    CurveLiquidityKind kind;
}

interface ICurveLiquidityResolver {
    function isFactoryGauge(
        address gauge,
        address lp
    ) external view returns (bool);
    function poolInfo(
        address poolOrLp
    ) external view returns (CurveLiquidityPool memory);
    function metaRegistry() external view returns (ICurveMetaRegistry);
    function metaRegistryForPool(
        address pool
    ) external view returns (ICurveMetaRegistry);
}
