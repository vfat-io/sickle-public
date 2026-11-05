// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    ICurveLiquidityResolver,
    CurveLiquidityPool,
    CurveLiquidityKind
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import { CurveLiquidityConnector } from "./CurveLiquidityConnector.sol";
import { CurveGaugeIdentity } from "./CurveGaugeIdentity.sol";
import {
    CurveSidechainGaugeConnector
} from "./CurveSidechainGaugeConnector.sol";
import { CurveGaugeConnector } from "./CurveGaugeConnector.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";
import {
    ICurveChildGaugeFactory
} from "contracts/interfaces/external/curve/ICurveChildGaugeFactory.sol";

/// @notice Curve-native pool registries and child factories authenticate all
/// families. CRV child gauges and reward-only gauges keep their own connectors.
contract CurveCrosschainLiquidityRegistry is ICustomConnectorRegistry {
    error InvalidConnector();
    error InvalidFactory();

    ICurveLiquidityResolver public immutable resolver;
    address public immutable gaugeConnector;
    address public immutable gaugeFactory;
    address public immutable legacyGaugeFactory;
    mapping(CurveLiquidityKind => address) public poolConnectors;

    constructor(
        ICurveLiquidityResolver resolver_,
        address[4] memory pools,
        address gaugeConnector_,
        address gaugeFactory_,
        address legacyGaugeFactory_,
        bool crvEmission
    ) {
        if (
            gaugeFactory_.code.length == 0
                || legacyGaugeFactory_ == gaugeFactory_
                || (legacyGaugeFactory_ != address(0)
                    && legacyGaugeFactory_.code.length == 0)
        ) revert InvalidFactory();
        if (crvEmission) {
            CurveSidechainGaugeConnector gauge =
                CurveSidechainGaugeConnector(gaugeConnector_);
            if (
                gauge.childGaugeFactory() != gaugeFactory_
                    || gauge.legacyChildGaugeFactory() != legacyGaugeFactory_
            ) revert InvalidConnector();
        } else if (CurveGaugeConnector(gaugeConnector_).minter() != address(0))
        {
            revert InvalidConnector();
        }
        resolver = resolver_;
        gaugeConnector = gaugeConnector_;
        gaugeFactory = gaugeFactory_;
        legacyGaugeFactory = legacyGaugeFactory_;
        for (uint256 i; i < pools.length; i++) {
            CurveLiquidityConnector connector =
                CurveLiquidityConnector(pools[i]);
            CurveLiquidityKind kind = CurveLiquidityKind(i + 1);
            if (
                address(connector.resolver()) != address(resolver_)
                    || connector.poolKind() != kind
            ) revert InvalidConnector();
            poolConnectors[kind] = pools[i];
        }
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        address factory = CurveGaugeIdentity.readAddress(
            target, abi.encodeCall(ICurveGauge.factory, ())
        );
        if (
            factory == gaugeFactory
                || (factory != address(0) && factory == legacyGaugeFactory)
        ) {
            try ICurveChildGaugeFactory(factory)
                .is_valid_gauge(target) returns (
                bool valid
            ) {
                if (valid) {
                    return gaugeConnector;
                }
            } catch { }
        }
        try resolver.poolInfo(target) returns (CurveLiquidityPool memory pool) {
            return poolConnectors[pool.kind];
        } catch { }
        return address(0);
    }
}
