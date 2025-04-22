// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;
pragma abicoder v2;

enum YieldMode {
    AUTOMATIC,
    VOID,
    CLAIMABLE
}
/// @title The interface for the Algebra Factory
/// @dev Credit to Uniswap Labs under GPL-2.0-or-later license:
/// https://github.com/Uniswap/v3-core/tree/main/contracts/interfaces

interface IAlgebraFactory {
    /// @notice Emitted when a process of ownership renounce is started
    /// @param timestamp The timestamp of event
    /// @param finishTimestamp The timestamp when ownership renounce will be
    /// possible to finish
    event RenounceOwnershipStart(uint256 timestamp, uint256 finishTimestamp);

    /// @notice Emitted when a process of ownership renounce cancelled
    /// @param timestamp The timestamp of event
    event RenounceOwnershipStop(uint256 timestamp);

    /// @notice Emitted when a process of ownership renounce finished
    /// @param timestamp The timestamp of ownership renouncement
    event RenounceOwnershipFinish(uint256 timestamp);

    /// @notice Emitted when a pool is created
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param pool The address of the created pool
    event Pool(address indexed token0, address indexed token1, address pool);

    /// @notice Emitted when the default community fee is changed
    /// @param newDefaultCommunityFee The new default community fee value
    event DefaultCommunityFee(uint16 newDefaultCommunityFee);

    /// @notice Emitted when the default tickspacing is changed
    /// @param newDefaultTickspacing The new default tickspacing value
    event DefaultTickspacing(int24 newDefaultTickspacing);

    /// @notice Emitted when the default fee is changed
    /// @param newDefaultFee The new default fee value
    event DefaultFee(uint16 newDefaultFee);

    /// @notice Emitted when the defaultPluginFactory address is changed
    /// @param defaultPluginFactoryAddress The new defaultPluginFactory address
    event DefaultPluginFactory(address defaultPluginFactoryAddress);

    /// @notice Emitted when the vaultFactory address is changed
    /// @param newVaultFactory The new vaultFactory address
    event VaultFactory(address newVaultFactory);

    /// @notice Emitted when the pools creation mode is changed
    /// @param mode_ The new pools creation mode
    event PublicPoolCreationMode(bool mode_);

    /// @dev Emitted when set new default blast governor address is changed.
    /// @param defaultBlastGovernor The new default blast governor address
    event DefaultBlastGovernor(address indexed defaultBlastGovernor);

    /// @dev Emitted when set new default blast points address is changed.
    /// @param defaultBlastPoints The new default blast points address
    event DefaultBlastPoints(address indexed defaultBlastPoints);

    /// @dev Emitted when set new default blast points operator address is
    /// changed.
    /// @param defaultBlastPointsOperator The new default blast points operator
    /// address
    event DefaultBlastPointsOperator(
        address indexed defaultBlastPointsOperator
    );

    /// @notice Emitted when the rebase configuration for a token is set or
    /// updated
    /// @param token The address of the token whose rebase configuration has
    /// been set or updated
    /// @param isRebase Indicates whether the token is set as a rebasing token
    /// @param mode The yield mode that has been set for the token, defining its
    /// rebasing behavior
    event ConfigurationForRebaseToken(
        address token, bool isRebase, YieldMode mode
    );

    /// @dev Emitted when the rebasing tokens governor address is set.
    /// @param oldRebasingTokensGovernor The previous address of the rebasing
    /// tokens governor.
    /// @param newRebasingTokensGovernor The new address of the rebasing tokens
    /// governor.
    event SetRebasingTokensGovernor(
        address indexed oldRebasingTokensGovernor,
        address indexed newRebasingTokensGovernor
    );

    /// @notice role that can change communityFee and tickspacing in pools
    /// @return The hash corresponding to this role
    function POOLS_ADMINISTRATOR_ROLE() external view returns (bytes32);

    /// @notice role that can create pools when public pool creation is disabled
    /// @return The hash corresponding to this role
    function POOLS_CREATOR_ROLE() external view returns (bytes32);

    /// @notice Returns `true` if `account` has been granted `role` or `account`
    /// is owner.
    /// @param role The hash corresponding to the role
    /// @param account The address for which the role is checked
    /// @return bool Whether the address has this role or the owner role or not
    function hasRoleOrOwner(
        bytes32 role,
        address account
    ) external view returns (bool);

    /// @notice Returns the current owner of the factory
    /// @dev Can be changed by the current owner via transferOwnership(address
    /// newOwner)
    /// @return The address of the factory owner
    function owner() external view returns (address);

    /// @notice Returns the current default blast governor
    /// @return The address of the default blast governor
    function defaultBlastGovernor() external view returns (address);

    /// @notice Returns the current default blast points
    /// @return The address of the default blast points
    function defaultBlastPoints() external view returns (address);

    /// @notice Returns the current default blast points operator
    /// @return The address of the default blast points operator
    function defaultBlastPointsOperator() external view returns (address);

    /// @notice Retrieves the yield mode configuration for a specified token
    /// @param token The address of the token for which to retrieve the yield
    /// mode
    /// @return The yield mode (rebasing configuration) set for the given token
    function configurationForBlastRebaseTokens(
        address token
    ) external view returns (YieldMode);

    /// @notice Return if a token is marked as a rebasing token in the factory
    /// configuration
    /// @param token The address of the token to check
    /// @return True if the token is a rebasing token, false otherwise
    function isRebaseToken(
        address token
    ) external view returns (bool);

    /// @notice Returns the current poolDeployerAddress
    /// @return The address of the poolDeployer
    function poolDeployer() external view returns (address);

    /// @notice Returns the status of enable public pool creation mode
    /// @return bool Whether the public creation mode is enable or not
    function isPublicPoolCreationMode() external view returns (bool);

    /// @notice Returns the default community fee
    /// @return Fee which will be set at the creation of the pool
    function defaultCommunityFee() external view returns (uint16);

    /// @notice Returns the default fee
    /// @return Fee which will be set at the creation of the pool
    function defaultFee() external view returns (uint16);

    /// @notice Returns the default tickspacing
    /// @return Tickspacing which will be set at the creation of the pool
    function defaultTickspacing() external view returns (int24);

    /// @notice Return the current pluginFactory address
    /// @dev This contract is used to automatically set a plugin address in new
    /// liquidity pools
    /// @return Algebra plugin factory
    function defaultPluginFactory() external view returns (address);

    /// @notice Address of the rebasing tokens governor
    /// @return rebasing tokens governor
    function rebasingTokensGovernor() external view returns (address);

    /// @notice Return the current vaultFactory address
    /// @dev This contract is used to automatically set a vault address in new
    /// liquidity pools
    /// @return Algebra vault factory
    function vaultFactory() external view returns (address);

    /// @notice Returns the default communityFee, tickspacing, fee and
    /// communityFeeVault for pool
    /// @param pool the address of liquidity pool
    /// @return communityFee which will be set at the creation of the pool
    /// @return tickSpacing which will be set at the creation of the pool
    /// @return fee which will be set at the creation of the pool
    /// @return communityFeeVault the address of communityFeeVault
    function defaultConfigurationForPool(
        address pool
    )
        external
        view
        returns (
            uint16 communityFee,
            int24 tickSpacing,
            uint16 fee,
            address communityFeeVault
        );

    /// @notice Deterministically computes the pool address given the token0 and
    /// token1
    /// @dev The method does not check if such a pool has been created
    /// @param token0 first token
    /// @param token1 second token
    /// @return pool The contract address of the Algebra pool
    function computePoolAddress(
        address token0,
        address token1
    ) external view returns (address pool);

    /// @notice Returns the pool address for a given pair of tokens, or address
    /// 0 if it does not exist
    /// @dev tokenA and tokenB may be passed in either token0/token1 or
    /// token1/token0 order
    /// @param tokenA The contract address of either token0 or token1
    /// @param tokenB The contract address of the other token
    /// @return pool The pool address
    function poolByPair(
        address tokenA,
        address tokenB
    ) external view returns (address pool);

    /// @notice returns keccak256 of AlgebraPool init bytecode.
    /// @dev the hash value changes with any change in the pool bytecode
    /// @return Keccak256 hash of AlgebraPool contract init bytecode
    function POOL_INIT_CODE_HASH() external view returns (bytes32);

    /// @return timestamp The timestamp of the beginning of the
    /// renounceOwnership process
    function renounceOwnershipStartTimestamp()
        external
        view
        returns (uint256 timestamp);

    /// @notice Creates a pool for the given two tokens
    /// @param tokenA One of the two tokens in the desired pool
    /// @param tokenB The other of the two tokens in the desired pool
    /// @dev tokenA and tokenB may be passed in either order: token0/token1 or
    /// token1/token0.
    /// The call will revert if the pool already exists or the token arguments
    /// are invalid.
    /// @return pool The address of the newly created pool
    function createPool(
        address tokenA,
        address tokenB
    ) external returns (address pool);

    /// @dev updates pools creation mode
    /// @param mode_ the new mode for pools creation proccess
    function setIsPublicPoolCreationMode(
        bool mode_
    ) external;

    /// @notice Sets the rebase configuration for a specific token
    /// @param token_ The address of the token to configure
    /// @param isRebase_ A boolean indicating whether the token is a rebasing
    /// token or not
    /// @param mode_ The yield mode to apply, defining how the rebasing
    /// mechanism should operate
    function setConfigurationForRebaseToken(
        address token_,
        bool isRebase_,
        YieldMode mode_
    ) external;

    /// @notice Sets the address of the rebasing tokens governor.
    /// @dev Updates the address of the rebasing tokens governor. Can only be
    /// called by an account with the DEFAULT_ADMIN_ROLE.
    /// @param rebasingTokensGovernor_ The new address of the rebasing tokens
    /// governor.
    /// Emits a {SetRebasingTokensGovernor} event.
    function setRebasingTokensGovernor(
        address rebasingTokensGovernor_
    ) external;

    /// @dev updates default community fee for new pools
    /// @param newDefaultCommunityFee The new community fee, _must_ be <=
    /// MAX_COMMUNITY_FEE
    function setDefaultCommunityFee(
        uint16 newDefaultCommunityFee
    ) external;

    /// @dev updates default fee for new pools
    /// @param newDefaultFee The new  fee, _must_ be <= MAX_DEFAULT_FEE
    function setDefaultFee(
        uint16 newDefaultFee
    ) external;

    /// @dev updates default tickspacing for new pools
    /// @param newDefaultTickspacing The new tickspacing, _must_ be <=
    /// MAX_TICK_SPACING and >= MIN_TICK_SPACING
    function setDefaultTickspacing(
        int24 newDefaultTickspacing
    ) external;

    /// @dev updates pluginFactory address
    /// @param newDefaultPluginFactory address of new plugin factory
    function setDefaultPluginFactory(
        address newDefaultPluginFactory
    ) external;

    /// @dev updates vaultFactory address
    /// @param newVaultFactory address of new vault factory
    function setVaultFactory(
        address newVaultFactory
    ) external;

    /// @notice Starts process of renounceOwnership. After that, a certain
    /// period
    /// of time must pass before the ownership renounce can be completed.
    function startRenounceOwnership() external;

    /// @notice Stops process of renounceOwnership and removes timer.
    function stopRenounceOwnership() external;

    /// @dev updates default blast governor address on the factory
    /// @param defaultBlastGovernor_ The new defautl blast governor address
    function setDefaultBlastGovernor(
        address defaultBlastGovernor_
    ) external;

    /// @dev updates default blast points address on the factory
    /// @param defaultBlastPoints_ The new defautl blast points address
    function setDefaultBlastPoints(
        address defaultBlastPoints_
    ) external;

    /// @dev updates default blast points operator address on the factory
    /// @param defaultBlastPointsOperator_ The new defautl blast points operator
    /// address
    function setDefaultBlastPointsOperator(
        address defaultBlastPointsOperator_
    ) external;
}
