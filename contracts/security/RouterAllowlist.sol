// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { GuardianAdmin } from "contracts/base/GuardianAdmin.sol";
import { IRouterAllowlist } from "contracts/interfaces/IRouterAllowlist.sol";

/// @title RouterAllowlist
/// @notice On-chain registry of allowed DEX routers for SwapRouter
contract RouterAllowlist is GuardianAdmin, IRouterAllowlist {
    /// ERRORS ///
    error RouterNotAllowed(address router);
    error FactoryNotAllowed(address factory);
    error CustomDeployerNotAllowed(address factory, address deployer);
    error HookNotAllowed(address hook);
    error BridgeNotAllowed(address bridge);
    error SelectorNotAllowed(address bridge, bytes4 selector);
    error BridgeRequiresSelectors();
    error DataLengthMismatch();
    error NotAContract(address addr);

    /// EVENTS ///

    event RouterAllowed(address indexed router);
    event RouterBlocked(address indexed router);
    event FactoryAllowed(address indexed factory);
    event FactoryBlocked(address indexed factory);
    event CustomDeployerAllowed(
        address indexed factory, address indexed deployer
    );
    event CustomDeployerBlocked(
        address indexed factory, address indexed deployer
    );
    event HookAllowed(address indexed hook);
    event HookBlocked(address indexed hook);
    event BridgeAllowed(address indexed bridge);
    event BridgeBlocked(address indexed bridge);
    event SelectorAllowed(address indexed bridge, bytes4 indexed selector);
    event SelectorBlocked(address indexed bridge, bytes4 indexed selector);

    /// STORAGE ///

    /// @inheritdoc IRouterAllowlist
    mapping(address => bool) public override isAllowed;
    address[] public allowedRouters;
    mapping(address => uint256) private _routerIndex;

    /// @inheritdoc IRouterAllowlist
    mapping(address => bool) public override isAllowedFactory;
    address[] public allowedFactories;
    mapping(address => uint256) private _factoryIndex;

    /// @inheritdoc IRouterAllowlist
    mapping(address => mapping(address => bool))
        public
        override isAllowedCustomDeployer;
    /// @inheritdoc IRouterAllowlist
    mapping(address => bool) public override isAllowedHook;
    address[] public allowedHooks;
    mapping(address => uint256) private _hookIndex;

    /// @inheritdoc IRouterAllowlist
    mapping(address => bool) public override isAllowedBridge;
    address[] public allowedBridges;
    mapping(address => uint256) private _bridgeIndex;

    /// @inheritdoc IRouterAllowlist
    mapping(address => mapping(bytes4 => bool))
        public
        override isAllowedSelector;
    mapping(address => bytes4[]) private _bridgeSelectors;
    mapping(address => mapping(bytes4 => uint256)) private
        _selectorIndexPlusOne;

    /// CONSTRUCTOR ///

    /// @param admin_ Address of the admin
    /// @param guardian_ Address of the initial guardian (may be zero)
    constructor(
        address admin_,
        address guardian_
    ) GuardianAdmin(admin_, guardian_) { }

    /// READ FUNCTIONS ///

    /// @inheritdoc IRouterAllowlist
    function requireAllowed(
        address router
    ) external view override {
        if (!isAllowed[router]) revert RouterNotAllowed(router);
    }

    /// @inheritdoc IRouterAllowlist
    function requireAllowedFactory(
        address factory
    ) external view override {
        if (!isAllowedFactory[factory]) revert FactoryNotAllowed(factory);
    }

    /// @inheritdoc IRouterAllowlist
    function requireAllowedCustomDeployer(
        address factory,
        address deployer
    ) external view override {
        if (!isAllowedCustomDeployer[factory][deployer]) {
            revert CustomDeployerNotAllowed(factory, deployer);
        }
    }

    /// @inheritdoc IRouterAllowlist
    function requireAllowedHook(
        address hook
    ) external view override {
        if (!isAllowedHook[hook]) revert HookNotAllowed(hook);
    }

    /// @inheritdoc IRouterAllowlist
    function requireAllowedBridge(
        address bridge
    ) external view override {
        if (!isAllowedBridge[bridge]) revert BridgeNotAllowed(bridge);
    }

    /// @inheritdoc IRouterAllowlist
    function requireAllowedSelector(
        address bridge,
        bytes4 selector
    ) external view override {
        if (!isAllowedSelector[bridge][selector]) {
            revert SelectorNotAllowed(bridge, selector);
        }
    }

    /// @inheritdoc IRouterAllowlist
    function bridgeSelectors(
        address bridge
    ) external view override returns (bytes4[] memory) {
        return _bridgeSelectors[bridge];
    }

    /// @notice Get the number of allowed routers
    /// @return The number of allowed routers
    function allowedRoutersLength() external view returns (uint256) {
        return allowedRouters.length;
    }

    /// @notice Get the number of allowed factories
    /// @return The number of allowed factories
    function allowedFactoriesLength() external view returns (uint256) {
        return allowedFactories.length;
    }

    /// WRITE FUNCTIONS ///

    /// @notice Set the allowed status for a single router
    /// @param router The router address
    /// @param allowed Whether the router is allowed
    function setRouter(
        address router,
        bool allowed
    ) external onlyAdmin {
        _setRouter(router, allowed);
    }

    /// @notice Set the allowed status for a single factory
    /// @param factory The factory address
    /// @param allowed Whether the factory is allowed
    function setFactory(
        address factory,
        bool allowed
    ) external onlyAdmin {
        _setFactory(factory, allowed);
    }

    /// @notice Set the allowed status for multiple routers
    /// @param routers Array of router addresses
    /// @param allowed Array of allowed statuses
    function setRouters(
        address[] calldata routers,
        bool[] calldata allowed
    ) external onlyAdmin {
        uint256 length = routers.length;
        if (length != allowed.length) revert DataLengthMismatch();
        for (uint256 i; i < length;) {
            _setRouter(routers[i], allowed[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Set the allowed status for multiple factories
    /// @param factories Array of factory addresses
    /// @param allowed Array of allowed statuses
    function setFactories(
        address[] calldata factories,
        bool[] calldata allowed
    ) external onlyAdmin {
        uint256 length = factories.length;
        if (length != allowed.length) revert DataLengthMismatch();
        for (uint256 i; i < length;) {
            _setFactory(factories[i], allowed[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Set the allowed status for a custom pool deployer
    /// @param factory The factory address
    /// @param deployer The custom pool deployer address
    /// @param allowed Whether the custom deployer is allowed
    function setCustomDeployer(
        address factory,
        address deployer,
        bool allowed
    ) external onlyAdmin {
        _setCustomDeployer(factory, deployer, allowed);
    }

    /// @notice Set the allowed status for multiple custom pool deployers
    /// @param factory The factory address
    /// @param deployers Array of custom deployer addresses
    /// @param allowed Array of allowed statuses
    function setCustomDeployers(
        address factory,
        address[] calldata deployers,
        bool[] calldata allowed
    ) external onlyAdmin {
        uint256 length = deployers.length;
        if (length != allowed.length) revert DataLengthMismatch();
        for (uint256 i; i < length;) {
            _setCustomDeployer(factory, deployers[i], allowed[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Set the allowed status for a v4 hook
    /// @param hook The hook address
    /// @param allowed Whether the hook is allowed
    function setHook(
        address hook,
        bool allowed
    ) external onlyAdmin {
        _setHook(hook, allowed);
    }

    /// @notice Set the allowed status for multiple v4 hooks
    /// @param hooks Array of hook addresses
    /// @param allowed Array of allowed statuses
    function setHooks(
        address[] calldata hooks,
        bool[] calldata allowed
    ) external onlyAdmin {
        uint256 length = hooks.length;
        if (length != allowed.length) revert DataLengthMismatch();
        for (uint256 i; i < length;) {
            _setHook(hooks[i], allowed[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get the number of allowed hooks
    /// @return The number of allowed hooks
    function allowedHooksLength() external view returns (uint256) {
        return allowedHooks.length;
    }

    /// @notice Get the number of allowed bridges
    /// @return The number of allowed bridges
    function allowedBridgesLength() external view returns (uint256) {
        return allowedBridges.length;
    }

    /// @notice Allow a bridge with at least one function selector
    /// @param bridge The bridge address
    /// @param selectors Array of allowed function selectors (must be non-empty)
    function setBridge(
        address bridge,
        bytes4[] calldata selectors
    ) external onlyAdmin {
        if (selectors.length == 0) revert BridgeRequiresSelectors();
        _setBridge(bridge, true);
        _replaceBridgeSelectors(bridge, selectors);
    }

    /// @notice Remove a bridge from the allowlist
    /// @param bridge The bridge address
    function removeBridge(
        address bridge
    ) external onlyAdmin {
        _clearBridgeSelectors(bridge);
        _setBridge(bridge, false);
    }

    /// @notice Emergency-disable a bridge without waiting on governance.
    /// Can only block an already-configured bridge; re-enabling still
    /// requires the admin path.
    function emergencyRemoveBridge(
        address bridge
    ) external onlyGuardianOrAdmin {
        _clearBridgeSelectors(bridge);
        _setBridge(bridge, false);
    }

    /// @notice Set the allowed status for a bridge function selector
    /// @param bridge The bridge contract address
    /// @param selector The function selector
    /// @param allowed Whether the selector is allowed
    function setSelector(
        address bridge,
        bytes4 selector,
        bool allowed
    ) external onlyAdmin {
        _setSelector(bridge, selector, allowed);
    }

    /// @notice Set the allowed status for multiple bridge function selectors
    /// @param bridge The bridge contract address
    /// @param selectors Array of function selectors
    /// @param allowed Array of allowed statuses
    function setSelectors(
        address bridge,
        bytes4[] calldata selectors,
        bool[] calldata allowed
    ) external onlyAdmin {
        uint256 length = selectors.length;
        if (length != allowed.length) revert DataLengthMismatch();
        for (uint256 i; i < length;) {
            _setSelector(bridge, selectors[i], allowed[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// INTERNAL FUNCTIONS ///

    function _setRouter(
        address router,
        bool allowed
    ) internal {
        if (allowed && router.code.length == 0) revert NotAContract(router);
        bool currentlyAllowed = isAllowed[router];
        if (currentlyAllowed == allowed) return;

        isAllowed[router] = allowed;
        if (allowed) {
            _routerIndex[router] = allowedRouters.length;
            allowedRouters.push(router);
            emit RouterAllowed(router);
        } else {
            uint256 index = _routerIndex[router];
            uint256 lastIndex = allowedRouters.length - 1;
            if (index != lastIndex) {
                address lastRouter = allowedRouters[lastIndex];
                allowedRouters[index] = lastRouter;
                _routerIndex[lastRouter] = index;
            }
            allowedRouters.pop();
            delete _routerIndex[router];
            emit RouterBlocked(router);
        }
    }

    function _setFactory(
        address factory,
        bool allowed
    ) internal {
        bool currentlyAllowed = isAllowedFactory[factory];
        if (currentlyAllowed == allowed) return;

        isAllowedFactory[factory] = allowed;
        if (allowed) {
            _factoryIndex[factory] = allowedFactories.length;
            allowedFactories.push(factory);
            emit FactoryAllowed(factory);
        } else {
            uint256 index = _factoryIndex[factory];
            uint256 lastIndex = allowedFactories.length - 1;
            if (index != lastIndex) {
                address lastFactory = allowedFactories[lastIndex];
                allowedFactories[index] = lastFactory;
                _factoryIndex[lastFactory] = index;
            }
            allowedFactories.pop();
            delete _factoryIndex[factory];
            emit FactoryBlocked(factory);
        }
    }

    function _setCustomDeployer(
        address factory,
        address deployer,
        bool allowed
    ) internal {
        bool currentlyAllowed = isAllowedCustomDeployer[factory][deployer];
        if (currentlyAllowed == allowed) return;

        isAllowedCustomDeployer[factory][deployer] = allowed;
        if (allowed) {
            emit CustomDeployerAllowed(factory, deployer);
        } else {
            emit CustomDeployerBlocked(factory, deployer);
        }
    }

    function _setHook(
        address hook,
        bool allowed
    ) internal {
        bool currentlyAllowed = isAllowedHook[hook];
        if (currentlyAllowed == allowed) return;

        isAllowedHook[hook] = allowed;
        if (allowed) {
            _hookIndex[hook] = allowedHooks.length;
            allowedHooks.push(hook);
            emit HookAllowed(hook);
        } else {
            uint256 index = _hookIndex[hook];
            uint256 lastIndex = allowedHooks.length - 1;
            if (index != lastIndex) {
                address lastHook = allowedHooks[lastIndex];
                allowedHooks[index] = lastHook;
                _hookIndex[lastHook] = index;
            }
            allowedHooks.pop();
            delete _hookIndex[hook];
            emit HookBlocked(hook);
        }
    }

    function _setBridge(
        address bridge,
        bool allowed
    ) internal {
        if (allowed && bridge.code.length == 0) revert NotAContract(bridge);
        bool currentlyAllowed = isAllowedBridge[bridge];
        if (currentlyAllowed == allowed) return;

        isAllowedBridge[bridge] = allowed;
        if (allowed) {
            _bridgeIndex[bridge] = allowedBridges.length;
            allowedBridges.push(bridge);
            emit BridgeAllowed(bridge);
        } else {
            uint256 index = _bridgeIndex[bridge];
            uint256 lastIndex = allowedBridges.length - 1;
            if (index != lastIndex) {
                address lastBridge = allowedBridges[lastIndex];
                allowedBridges[index] = lastBridge;
                _bridgeIndex[lastBridge] = index;
            }
            allowedBridges.pop();
            delete _bridgeIndex[bridge];
            emit BridgeBlocked(bridge);
        }
    }

    function _setSelector(
        address bridge,
        bytes4 selector,
        bool allowed
    ) internal {
        bool currentlyAllowed = isAllowedSelector[bridge][selector];
        if (currentlyAllowed == allowed) return;

        isAllowedSelector[bridge][selector] = allowed;
        if (allowed) {
            _selectorIndexPlusOne[bridge][selector] =
                _bridgeSelectors[bridge].length + 1;
            _bridgeSelectors[bridge].push(selector);
            emit SelectorAllowed(bridge, selector);
        } else {
            uint256 indexPlusOne = _selectorIndexPlusOne[bridge][selector];
            if (indexPlusOne != 0) {
                uint256 index = indexPlusOne - 1;
                uint256 lastIndex = _bridgeSelectors[bridge].length - 1;
                if (index != lastIndex) {
                    bytes4 lastSelector = _bridgeSelectors[bridge][lastIndex];
                    _bridgeSelectors[bridge][index] = lastSelector;
                    _selectorIndexPlusOne[bridge][lastSelector] = index + 1;
                }
                _bridgeSelectors[bridge].pop();
                delete _selectorIndexPlusOne[bridge][selector];
            }
            emit SelectorBlocked(bridge, selector);
        }
    }

    function _replaceBridgeSelectors(
        address bridge,
        bytes4[] calldata selectors
    ) internal {
        _clearBridgeSelectors(bridge);
        for (uint256 i; i < selectors.length;) {
            _setSelector(bridge, selectors[i], true);
            unchecked {
                ++i;
            }
        }
    }

    function _clearBridgeSelectors(
        address bridge
    ) internal {
        while (_bridgeSelectors[bridge].length > 0) {
            _setSelector(
                bridge,
                _bridgeSelectors[bridge][_bridgeSelectors[bridge].length - 1],
                false
            );
        }
    }
}
