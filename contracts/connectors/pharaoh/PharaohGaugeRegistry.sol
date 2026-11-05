// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { PharaohV2GaugeConnector } from
    "contracts/connectors/pharaoh/PharaohV2GaugeConnector.sol";

contract PharaohGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    PharaohV2GaugeConnector public immutable pharaohV2GaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        PharaohV2GaugeConnector pharaohV2GaugeConnector_
    ) {
        voter = voter_;
        pharaohV2GaugeConnector = pharaohV2GaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            return address(pharaohV2GaugeConnector);
        }

        return address(0);
    }
}
