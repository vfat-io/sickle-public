// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    FablesConnector
} from "contracts/connectors/fables/FablesConnector.sol";
import {
    IFablesPoolRegistry
} from "contracts/interfaces/external/fables/IFablesPoolRegistry.sol";

/// @notice Resolves Fables ledger hooks to `FablesConnector` via the on-chain
///         pool registry. New Fables markets resolve without a plan.json row.
contract FablesHookRegistry is ICustomConnectorRegistry {
    IFablesPoolRegistry public immutable poolRegistry;
    FablesConnector public immutable fablesConnector;

    constructor(
        IFablesPoolRegistry poolRegistry_,
        FablesConnector fablesConnector_
    ) {
        poolRegistry = poolRegistry_;
        fablesConnector = fablesConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        uint256 n = poolRegistry.poolCount();
        for (uint256 i; i < n;) {
            IFablesPoolRegistry.PoolInfo memory info = poolRegistry.poolAt(i);
            if (address(info.key.hooks) == target) {
                return address(fablesConnector);
            }
            unchecked {
                ++i;
            }
        }
        return address(0);
    }
}
