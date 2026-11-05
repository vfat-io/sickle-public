// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    ICurveStableSwapFactory
} from "contracts/interfaces/external/curve/ICurveStableSwapFactory.sol";
import {
    CurvePoolConnector
} from "contracts/connectors/curve/CurvePoolConnector.sol";
import {
    CurveSidechainGaugeConnector
} from "contracts/connectors/curve/CurveSidechainGaugeConnector.sol";

/// @notice Resolves StableSwap-NG pools and child gauges on CRV sidechains.
/// @dev Gauge validation remains in the connector so routing and claiming use
/// the exact same immutable factory allowlist.
contract CurveSidechainRegistry is ICustomConnectorRegistry {
    ICurveStableSwapFactory public immutable poolFactory;
    CurvePoolConnector public immutable poolConnector;
    CurveSidechainGaugeConnector public immutable gaugeConnector;

    constructor(
        ICurveStableSwapFactory poolFactory_,
        CurvePoolConnector poolConnector_,
        CurveSidechainGaugeConnector gaugeConnector_
    ) {
        poolFactory = poolFactory_;
        poolConnector = poolConnector_;
        gaugeConnector = gaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (poolFactory.get_n_coins(target) > 0) {
            return address(poolConnector);
        }

        if (gaugeConnector.isValidGauge(target)) {
            return address(gaugeConnector);
        }

        return address(0);
    }
}
