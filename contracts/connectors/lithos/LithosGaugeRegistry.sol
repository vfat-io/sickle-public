// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { LithosGaugeConnector } from
    "contracts/connectors/lithos/LithosGaugeConnector.sol";

contract LithosGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    LithosGaugeConnector public immutable v2LithosGaugeConnector;

    constructor(
        IGaugeRegistryVoter _voter,
        LithosGaugeConnector _v2LithosGaugeConnector
    ) {
        voter = _voter;
        v2LithosGaugeConnector = _v2LithosGaugeConnector;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            return address(v2LithosGaugeConnector);
        }
        return address(0);
    }
}
