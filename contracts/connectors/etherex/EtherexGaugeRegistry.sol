// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { EtherexV2GaugeConnector } from
    "contracts/connectors/etherex/EtherexV2GaugeConnector.sol";

contract EtherexGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    EtherexV2GaugeConnector public immutable v2GaugeConnector;

    constructor(
        IGaugeRegistryVoter _voter,
        EtherexV2GaugeConnector _v2GaugeConnector
    ) {
        voter = _voter;
        v2GaugeConnector = _v2GaugeConnector;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            return address(v2GaugeConnector);
        }
        return address(0);
    }
}
