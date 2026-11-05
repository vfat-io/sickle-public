// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IGaugeManager
} from "contracts/interfaces/external/blackhole/IGaugeManager.sol";
import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    HybraV3GaugeConnector
} from "contracts/connectors/hybra/HybraV3GaugeConnector.sol";

contract HybraGaugeRegistry is ICustomConnectorRegistry {
    IGaugeManager public immutable gaugeManager;
    HybraV3GaugeConnector public immutable v3GaugeConnector;

    constructor(
        IGaugeManager gaugeManager_,
        HybraV3GaugeConnector v3GaugeConnector_
    ) {
        gaugeManager = gaugeManager_;
        v3GaugeConnector = v3GaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (gaugeManager.isCLGauge(target)) {
            return address(v3GaugeConnector);
        }

        return address(0);
    }
}
