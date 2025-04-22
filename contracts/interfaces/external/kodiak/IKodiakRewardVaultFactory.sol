// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IKodiakRewardVaultFactory {
    // Events
    event BGTIncentiveDistributorSet(
        address indexed newBGTIncentiveDistributor,
        address indexed oldBGTIncentiveDistributor
    );
    event Initialized(uint64 version);
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
    event Upgraded(address indexed implementation);
    event VaultCreated(address indexed stakingToken, address indexed vault);

    // View Functions
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function UPGRADE_INTERFACE_VERSION()
        external
        view
        returns (string memory);
    function VAULT_MANAGER_ROLE() external view returns (bytes32);
    function VAULT_PAUSER_ROLE() external view returns (bytes32);
    function allVaults(
        uint256
    ) external view returns (address);
    function allVaultsLength() external view returns (uint256);
    function beacon() external view returns (address);
    function beaconDepositContract() external view returns (address);
    function bgt() external view returns (address);
    function bgtIncentiveDistributor() external view returns (address);
    function distributor() external view returns (address);
    function getRoleAdmin(
        bytes32 role
    ) external view returns (bytes32);
    function getVault(
        address stakingToken
    ) external view returns (address vault);
    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool);
    function predictRewardVaultAddress(
        address stakingToken
    ) external view returns (address);
    function proxiableUUID() external view returns (bytes32);
    function supportsInterface(
        bytes4 interfaceId
    ) external view returns (bool);

    // State-changing Functions
    function createRewardVault(
        address stakingToken
    ) external returns (address);
    function grantRole(bytes32 role, address account) external;
    function initialize(
        address _bgt,
        address _distributor,
        address _beaconDepositContract,
        address _governance,
        address _vaultImpl
    ) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
    function revokeRole(bytes32 role, address account) external;
    function setBGTIncentiveDistributor(
        address _bgtIncentiveDistributor
    ) external;
    function upgradeToAndCall(
        address newImplementation,
        bytes calldata data
    ) external payable;
}
