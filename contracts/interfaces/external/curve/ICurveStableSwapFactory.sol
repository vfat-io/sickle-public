// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICurveStableSwapFactory {
    // Structs
    struct BasePoolData {
        address lp_token;
        address[] coins;
        uint256 decimals;
        uint256 n_coins;
        uint8[] asset_types;
    }

    // Events
    event BasePoolAdded(address base_pool);
    event PlainPoolDeployed(
        address pool, address[] coins, uint256 A, uint256 fee, address deployer
    );
    event MetaPoolDeployed(
        address pool,
        address coin,
        address base_pool,
        uint256 A,
        uint256 fee,
        address deployer
    );
    event LiquidityGaugeDeployed(address pool, address gauge);

    // View Functions
    function find_pool_for_coins(
        address _from,
        address _to
    ) external view returns (address);
    function find_pool_for_coins(
        address _from,
        address _to,
        uint256 i
    ) external view returns (address);
    function get_base_pool(
        address _pool
    ) external view returns (address);
    function get_n_coins(
        address _pool
    ) external view returns (uint256);
    function get_meta_n_coins(
        address _pool
    ) external view returns (uint256, uint256);
    function get_coins(
        address _pool
    ) external view returns (address[] memory);
    function get_underlying_coins(
        address _pool
    ) external view returns (address[] memory);
    function get_decimals(
        address _pool
    ) external view returns (uint256[] memory);
    function get_underlying_decimals(
        address _pool
    ) external view returns (uint256[] memory);
    function get_metapool_rates(
        address _pool
    ) external view returns (uint256[] memory);
    function get_balances(
        address _pool
    ) external view returns (uint256[] memory);
    function get_underlying_balances(
        address _pool
    ) external view returns (uint256[] memory);
    function get_A(
        address _pool
    ) external view returns (uint256);
    function get_fees(
        address _pool
    ) external view returns (uint256, uint256);
    function get_admin_balances(
        address _pool
    ) external view returns (uint256[] memory);
    function get_coin_indices(
        address _pool,
        address _from,
        address _to
    ) external view returns (int128, int128, bool);
    function get_gauge(
        address _pool
    ) external view returns (address);
    function get_implementation_address(
        address _pool
    ) external view returns (address);
    function is_meta(
        address _pool
    ) external view returns (bool);
    function get_pool_asset_types(
        address _pool
    ) external view returns (uint8[] memory);
    function version() external view returns (string memory);
    function admin() external view returns (address);
    function future_admin() external view returns (address);
    function asset_types(
        uint8
    ) external view returns (string memory);
    function pool_list(
        uint256
    ) external view returns (address);
    function pool_count() external view returns (uint256);
    function base_pool_list(
        uint256
    ) external view returns (address);
    function base_pool_count() external view returns (uint256);
    function base_pool_data(
        address
    ) external view returns (BasePoolData memory);
    function base_pool_assets(
        address
    ) external view returns (bool);
    function pool_implementations(
        uint256
    ) external view returns (address);
    function metapool_implementations(
        uint256
    ) external view returns (address);
    function math_implementation() external view returns (address);
    function gauge_implementation() external view returns (address);
    function views_implementation() external view returns (address);
    function fee_receiver() external view returns (address);

    // State-Changing Functions
    function deploy_plain_pool(
        string memory _name,
        string memory _symbol,
        address[] memory _coins,
        uint256 _A,
        uint256 _fee,
        uint256 _offpeg_fee_multiplier,
        uint256 _ma_exp_time,
        uint256 _implementation_idx,
        uint8[] memory _asset_types,
        bytes4[] memory _method_ids,
        address[] memory _oracles
    ) external returns (address);

    function deploy_metapool(
        address _base_pool,
        string memory _name,
        string memory _symbol,
        address _coin,
        uint256 _A,
        uint256 _fee,
        uint256 _offpeg_fee_multiplier,
        uint256 _ma_exp_time,
        uint256 _implementation_idx,
        uint8 _asset_type,
        bytes4 _method_id,
        address _oracle
    ) external returns (address);

    function deploy_gauge(
        address _pool
    ) external returns (address);
    function add_base_pool(
        address _base_pool,
        address _base_lp_token,
        uint8[] memory _asset_types,
        uint256 _n_coins
    ) external;
    function set_pool_implementations(
        uint256 _implementation_index,
        address _implementation
    ) external;
    function set_metapool_implementations(
        uint256 _implementation_index,
        address _implementation
    ) external;
    function set_math_implementation(
        address _math_implementation
    ) external;
    function set_gauge_implementation(
        address _gauge_implementation
    ) external;
    function set_views_implementation(
        address _views_implementation
    ) external;
    function set_owner(
        address _owner
    ) external;
    function commit_transfer_ownership(
        address _addr
    ) external;
    function accept_transfer_ownership() external;
    function set_fee_receiver(address _pool, address _fee_receiver) external;
    function add_asset_type(uint8 _id, string memory _name) external;
}
