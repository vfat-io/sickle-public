// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IRouterAllowlist {
    /// @notice Check if a router is allowed
    /// @param router The router address to check
    /// @return True if the router is allowed
    function isAllowed(address router) external view returns (bool);

    /// @notice Revert if the router is not allowed
    /// @param router The router address to check
    function requireAllowed(address router) external view;

    /// @notice Check if a factory is allowed
    /// @param factory The factory address to check
    /// @return True if the factory is allowed
    function isAllowedFactory(address factory) external view returns (bool);

    /// @notice Revert if the factory is not allowed
    /// @param factory The factory address to check
    function requireAllowedFactory(address factory) external view;

    /// @notice Check if a custom pool deployer is allowed for a factory
    /// @param factory The factory address to check
    /// @param deployer The custom pool deployer address to check
    /// @return True if the custom deployer is allowed for the factory
    function isAllowedCustomDeployer(address factory, address deployer) external view returns (bool);

    /// @notice Revert if the custom pool deployer is not allowed for a factory
    /// @param factory The factory address to check
    /// @param deployer The custom pool deployer address to check
    function requireAllowedCustomDeployer(address factory, address deployer) external view;

    /// @notice Check if a v4 hook is allowed
    /// @param hook The hook address to check
    /// @return True if the hook is allowed
    function isAllowedHook(address hook) external view returns (bool);

    /// @notice Revert if the v4 hook is not allowed
    /// @param hook The hook address to check
    function requireAllowedHook(address hook) external view;

    /// @notice Check if a bridge contract is allowed
    /// @param bridge The bridge contract address
    /// @return True if the bridge is allowed
    function isAllowedBridge(address bridge) external view returns (bool);

    /// @notice Revert if the bridge contract is not allowed
    /// @param bridge The bridge contract address
    function requireAllowedBridge(address bridge) external view;

    /// @notice Check if a function selector is allowed for a bridge contract
    /// @param bridge The bridge contract address
    /// @param selector The function selector
    /// @return True if the selector is allowed
    function isAllowedSelector(address bridge, bytes4 selector) external view returns (bool);

    /// @notice Revert if the function selector is not allowed for a bridge contract
    /// @param bridge The bridge contract address
    /// @param selector The function selector
    function requireAllowedSelector(address bridge, bytes4 selector) external view;

    /// @notice Enumerate the currently-allowed function selectors for a bridge
    /// @param bridge The bridge contract address
    /// @return selectors The set of selectors currently marked allowed for the bridge
    function bridgeSelectors(address bridge) external view returns (bytes4[] memory selectors);
}
