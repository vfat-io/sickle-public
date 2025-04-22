// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { ICurveGauge } from
    "contracts/interfaces/external/curve/ICurveGauge.sol";
import { ICurveXChainLiquidityGaugeFactory } from
    "contracts/interfaces/external/curve/ICurveXChainLiquidityGaugeFactory.sol";
import { ICurveStableSwapFactory } from
    "contracts/interfaces/external/curve/ICurveStableSwapFactory.sol";
import { CurvePoolConnector } from
    "contracts/connectors/curve/CurvePoolConnector.sol";
import { CurveGaugeConnector } from
    "contracts/connectors/curve/CurveGaugeConnector.sol";

contract CurveRegistry is ICustomConnectorRegistry {
    ICurveXChainLiquidityGaugeFactory public immutable gaugeFactory;
    ICurveStableSwapFactory public immutable poolFactory;
    CurvePoolConnector public immutable poolConnector;
    CurveGaugeConnector public immutable gaugeConnector;

    constructor(
        ICurveXChainLiquidityGaugeFactory gaugeFactory_,
        ICurveStableSwapFactory poolFactory_,
        CurvePoolConnector poolConnector_,
        CurveGaugeConnector gaugeConnector_
    ) {
        gaugeFactory = gaugeFactory_;
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

        if (gaugeFactory.is_valid_gauge(target)) {
            return address(gaugeConnector);
        }

        return address(0);
    }
}
