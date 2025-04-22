// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICurveXChainLiquidityGaugeFactory {
    // Events
    event DeployedGauge(
        address indexed _implementation,
        address indexed _lp_token,
        address indexed _deployer,
        bytes32 _salt,
        address _gauge
    );

    event Minted(
        address indexed _user, address indexed _gauge, uint256 _new_total
    );

    event UpdateImplementation(
        address _old_implementation, address _new_implementation
    );

    event UpdateVotingEscrow(
        address _old_voting_escrow, address _new_voting_escrow
    );

    event UpdateRoot(address _factory, address _implementation);

    event UpdateManager(address _manager);

    event UpdateCallProxy(address _old_call_proxy, address _new_call_proxy);

    event UpdateMirrored(address indexed _gauge, bool _mirrored);

    event TransferOwnership(address _old_owner, address _new_owner);

    // View Functions
    function version() external pure returns (string memory);
    function crv() external view returns (address);
    function get_implementation() external view returns (address);
    function voting_escrow() external view returns (address);
    function owner() external view returns (address);
    function future_owner() external view returns (address);
    function manager() external view returns (address);
    function root_factory() external view returns (address);
    function root_implementation() external view returns (address);
    function call_proxy() external view returns (address);
    function gauge_data(
        address
    ) external view returns (uint256);
    function minted(address, address) external view returns (uint256);
    function get_gauge_from_lp_token(
        address
    ) external view returns (address);
    function get_gauge_count() external view returns (uint256);
    function get_gauge(
        uint256
    ) external view returns (address);
    function is_valid_gauge(
        address _gauge
    ) external view returns (bool);
    function is_mirrored(
        address _gauge
    ) external view returns (bool);
    function last_request(
        address _gauge
    ) external view returns (uint256);

    // State-Changing Functions
    function set_owner(
        address _owner
    ) external;
    function mint(
        address _gauge
    ) external;
    function mint_many(
        address[32] calldata _gauges
    ) external;
    function deploy_gauge(
        address _lp_token,
        bytes32 _salt,
        address _manager
    ) external returns (address);
    function set_crv(
        address _crv
    ) external;
    function set_root(address _factory, address _implementation) external;
    function set_voting_escrow(
        address _voting_escrow
    ) external;
    function set_implementation(
        address _implementation
    ) external;
    function set_mirrored(address _gauge, bool _mirrored) external;
    function set_call_proxy(
        address _new_call_proxy
    ) external;
    function set_manager(
        address _new_manager
    ) external;
    function commit_transfer_ownership(
        address _future_owner
    ) external;
    function accept_transfer_ownership() external;
}
