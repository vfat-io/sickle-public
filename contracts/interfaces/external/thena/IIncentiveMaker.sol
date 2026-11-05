// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Structs
struct IncentiveKey {
    address rewardToken;
    address bonusRewardToken;
    address pool;
    uint256 nonce;
}

// Main contract interface
interface IIncentiveMaker {
    // Custom errors
    error IncentiveExists();
    error NotGauge();
    error NotPlugin();
    error RewardAmount();
    error ZeroAddress();

    // Events
    event Initialized(uint8 version);
    event RoleAdminChanged(
        bytes32 indexed role,
        bytes32 indexed previousAdminRole,
        bytes32 indexed newAdminRole
    );
    event RoleGranted(
        bytes32 indexed role, address indexed account, address indexed sender
    );
    event RoleRevoked(
        bytes32 indexed role, address indexed account, address indexed sender
    );
    event SetEternalFarming(address algebraEternalFarming);

    // Constants
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function INCENTIVE_MAKER_MANAGER_ROLE() external view returns (bytes32);
    function MINIMAL_POSITION_WIDTH() external view returns (uint24);

    // State variables
    function algebraEternalFarming() external view returns (address);
    function farmingCenter() external view returns (address);
    function thena() external view returns (address);
    function voter() external view returns (address);
    function wbnb() external view returns (address);

    // Initialization functions
    function _initialize(
        address _algebraEternalFarming,
        address _voter
    ) external;
    function initialize(address _thena, address _wbnb) external;

    // Core functionality
    function createIncentive(
        address pool,
        uint128 theamount,
        uint128 wbnbamount
    ) external returns (address);

    function updateIncentive(address pool, uint256 reward) external;
    function updateExtraIncentive(address pool, uint128 reward) external;

    // View functions
    function poolToKey(
        address pool
    )
        external
        view
        returns (
            address rewardToken,
            address bonusRewardToken,
            address pool_,
            uint256 nonce
        );

    function poolToVirtualPool(
        address pool
    ) external view returns (address virtualFarmingPool);

    // Role management functions
    function getRoleAdmin(
        bytes32 role
    ) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool);
    function renounceRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;

    // Configuration functions
    function setAlgebraEnternalFarming(
        address _algebraEternalFarming
    ) external;
    function setFarmingCenter(
        address _farmingCenter
    ) external;
    function setPoolToKey(
        IncentiveKey calldata key
    ) external;

    // Interface support
    function supportsInterface(
        bytes4 interfaceId
    ) external view returns (bool);
}
