// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    SwaphoodV2GaugeConnector
} from "contracts/connectors/swaphood/SwaphoodV2GaugeConnector.sol";
import {
    SwaphoodMasterchefV3Connector
} from "contracts/connectors/swaphood/SwaphoodMasterchefV3Connector.sol";
import {
    ISwaphoodMasterchefV2
} from "contracts/interfaces/external/swaphood/ISwaphoodMasterchefV2.sol";

contract SwaphoodStakingRegistry is ICustomConnectorRegistry {
    ISwaphoodMasterchefV2 public immutable masterchefV2;
    address public immutable masterchefV3;
    SwaphoodV2GaugeConnector public immutable v2GaugeConnector;
    SwaphoodMasterchefV3Connector public immutable masterchefV3Connector;

    constructor(
        ISwaphoodMasterchefV2 masterchefV2_,
        address masterchefV3_,
        SwaphoodV2GaugeConnector v2GaugeConnector_,
        SwaphoodMasterchefV3Connector masterchefV3Connector_
    ) {
        masterchefV2 = masterchefV2_;
        masterchefV3 = masterchefV3_;
        v2GaugeConnector = v2GaugeConnector_;
        masterchefV3Connector = masterchefV3Connector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (masterchefV2.isGauge(target)) {
            // The chef registers membership and its pid together. Membership
            // survives killing a gauge so its existing stakes can still exit.
            return address(v2GaugeConnector);
        }

        if (target == masterchefV3) {
            return address(masterchefV3Connector);
        }

        return address(0);
    }
}
