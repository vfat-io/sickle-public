// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    ILBHooksRewarder
} from "contracts/interfaces/external/lfj/ILBHooksRewarder.sol";

/// @notice Resolves rewarders for accepted bin pools. A former hook remains
/// resolvable so its bin shares can be exited after the pair rotates hooks.
contract LBHooksRewarderRegistry is ICustomConnectorRegistry {
    ICustomConnectorRegistry public immutable pairRegistry;
    address public immutable rewarderConnector;

    constructor(
        ICustomConnectorRegistry pairRegistry_,
        address rewarderConnector_
    ) {
        pairRegistry = pairRegistry_;
        rewarderConnector = rewarderConnector_;
    }

    function connectorOf(
        address target
    ) external view returns (address) {
        address pair = ILBHooksRewarder(target).getLBPair();
        if (pairRegistry.connectorOf(pair) == address(0)) return address(0);
        return rewarderConnector;
    }
}
