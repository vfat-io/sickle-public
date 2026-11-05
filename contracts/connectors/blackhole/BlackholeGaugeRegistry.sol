// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IGaugeManager } from
    "contracts/interfaces/external/blackhole/IGaugeManager.sol";
import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { BlackholeGaugeConnector } from
    "contracts/connectors/blackhole/BlackholeGaugeConnector.sol";
import { BlackholeV3GaugeConnector } from
    "contracts/connectors/blackhole/BlackholeV3GaugeConnector.sol";

contract BlackholeGaugeRegistry is ICustomConnectorRegistry {
    IGaugeManager public immutable gaugeManager;
    BlackholeGaugeConnector public immutable v2GaugeConnector;
    BlackholeV3GaugeConnector public immutable v3GaugeConnector;

    constructor(
        IGaugeManager gaugeManager_,
        BlackholeGaugeConnector v2GaugeConnector_,
        BlackholeV3GaugeConnector v3GaugeConnector_
    ) {
        gaugeManager = gaugeManager_;
        v2GaugeConnector = v2GaugeConnector_;
        v3GaugeConnector = v3GaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (gaugeManager.isCLGauge(target)) {
            return address(v3GaugeConnector);
        }

        if (gaugeManager.isGauge(target)) {
            return address(v2GaugeConnector);
        }

        return address(0);
    }
}
