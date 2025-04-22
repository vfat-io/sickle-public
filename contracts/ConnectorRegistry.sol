// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Admin } from "contracts/base/Admin.sol";
import { TimelockAdmin } from "contracts/base/TimelockAdmin.sol";

error ConnectorNotRegistered(address target);
error CustomRegistryAlreadyRegistered();

interface ICustomConnectorRegistry {
    function connectorOf(
        address target
    ) external view returns (address);
}

contract ConnectorRegistry is Admin, TimelockAdmin {
    event ConnectorChanged(address target, address connector);
    event CustomRegistryAdded(address registry);
    event CustomRegistryRemoved(address registry);

    error ConnectorAlreadySet(address target);
    error ConnectorNotSet(address target);
    error ArrayLengthMismatch();

    ICustomConnectorRegistry[] public customRegistries;

    mapping(address target => address connector) private connectors_;

    constructor(
        address admin_,
        address timelockAdmin_
    ) Admin(admin_) TimelockAdmin(timelockAdmin_) { }

    /// Admin functions

    /// @notice Update connector addresses for a batch of targets.
    /// @dev Controls which connector contracts are used for the specified
    /// targets.
    /// @custom:access Restricted to protocol admin.
    function setConnectors(
        address[] calldata targets,
        address[] calldata connectors
    ) external onlyAdmin {
        if (targets.length != connectors.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i != targets.length;) {
            if (connectors_[targets[i]] != address(0)) {
                revert ConnectorAlreadySet(targets[i]);
            }
            connectors_[targets[i]] = connectors[i];
            emit ConnectorChanged(targets[i], connectors[i]);

            unchecked {
                ++i;
            }
        }
    }

    function updateConnectors(
        address[] calldata targets,
        address[] calldata connectors
    ) external onlyTimelockAdmin {
        if (targets.length != connectors.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i != targets.length;) {
            if (connectors_[targets[i]] == address(0)) {
                revert ConnectorNotSet(targets[i]);
            }
            connectors_[targets[i]] = connectors[i];
            emit ConnectorChanged(targets[i], connectors[i]);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Append an address to the custom registries list.
    /// @custom:access Restricted to protocol admin.
    function addCustomRegistry(
        ICustomConnectorRegistry registry
    ) external onlyAdmin {
        if (isCustomRegistry(registry)) {
            revert CustomRegistryAlreadyRegistered();
        }

        customRegistries.push(registry);
        emit CustomRegistryAdded(address(registry));
    }

    /// @notice Replace an address in the custom registries list.
    /// @custom:access Restricted to protocol admin.
    function updateCustomRegistry(
        uint256 index,
        ICustomConnectorRegistry newRegistry
    ) external onlyTimelockAdmin {
        ICustomConnectorRegistry oldRegistry = customRegistries[index];
        emit CustomRegistryRemoved(address(oldRegistry));
        customRegistries[index] = newRegistry;
        if (address(newRegistry) != address(0)) {
            emit CustomRegistryAdded(address(newRegistry));
        }
    }

    /// Public functions

    function connectorOf(
        address target
    ) external view returns (address) {
        address connector = _getConnector(target);

        if (connector != address(0)) {
            return connector;
        }

        revert ConnectorNotRegistered(target);
    }

    function hasConnector(
        address target
    ) external view returns (bool) {
        return _getConnector(target) != address(0);
    }

    function isCustomRegistry(
        ICustomConnectorRegistry registry
    ) public view returns (bool) {
        for (uint256 i; i != customRegistries.length;) {
            if (address(customRegistries[i]) == address(registry)) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// Internal functions

    function _getConnector(
        address target
    ) internal view returns (address) {
        address connector = connectors_[target];
        if (connector != address(0)) {
            return connector;
        }
        uint256 length = customRegistries.length;
        for (uint256 i; i != length;) {
            if (address(customRegistries[i]) != address(0)) {
                (bool success, bytes memory data) = address(customRegistries[i])
                    .staticcall(
                    abi.encodeWithSelector(
                        ICustomConnectorRegistry.connectorOf.selector, target
                    )
                );
                if (success && data.length == 32) {
                    address _connector = abi.decode(data, (address));
                    if (_connector != address(0)) {
                        return _connector;
                    }
                }
            }

            unchecked {
                ++i;
            }
        }

        return address(0);
    }
}
