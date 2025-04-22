// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { ShadowV2GaugeConnector } from
    "contracts/connectors/shadow/ShadowV2GaugeConnector.sol";
import { ShadowV3GaugeConnector } from
    "contracts/connectors/shadow/ShadowV3GaugeConnector.sol";

contract ShadowGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    ShadowV2GaugeConnector public immutable shadowV2GaugeConnector;
    ShadowV3GaugeConnector public immutable shadowV3GaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        ShadowV2GaugeConnector shadowV2GaugeConnector_,
        ShadowV3GaugeConnector shadowV3GaugeConnector_
    ) {
        voter = voter_;
        shadowV2GaugeConnector = shadowV2GaugeConnector_;
        shadowV3GaugeConnector = shadowV3GaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isClGauge(target)) {
            return address(shadowV3GaugeConnector);
        }
        if (voter.isGauge(target)) {
            return address(shadowV2GaugeConnector);
        }

        return address(0);
    }
}
