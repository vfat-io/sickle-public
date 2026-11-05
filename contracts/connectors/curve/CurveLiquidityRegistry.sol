// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    ICurveLiquidityResolver,
    CurveLiquidityPool,
    CurveLiquidityKind
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import { CurveLiquidityConnector } from "./CurveLiquidityConnector.sol";
import { CurveModernGaugeConnector } from "./CurveModernGaugeConnector.sol";
import { CurveGaugeRewards } from "./CurveGaugeConnectorBase.sol";
import { CurveGaugeIdentity } from "./CurveGaugeIdentity.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";

contract CurveLiquidityRegistry is ICustomConnectorRegistry {
    error InvalidConnector();
    ICurveLiquidityResolver public immutable resolver;
    address public immutable gaugeConnector;
    mapping(CurveLiquidityKind => address) public poolConnectors;

    constructor(
        ICurveLiquidityResolver resolver_,
        address[3] memory pools,
        CurveModernGaugeConnector gaugeConnector_
    ) {
        resolver = resolver_;
        if (
            address(gaugeConnector_.resolver()) != address(resolver_)
                || gaugeConnector_.rewardType() != CurveGaugeRewards.Modern
        ) revert InvalidConnector();
        gaugeConnector = address(gaugeConnector_);
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
        address lp = CurveGaugeIdentity.readAddress(
            target, abi.encodeCall(ICurveGauge.lp_token, ())
        );
        if (lp != address(0) && resolver.isFactoryGauge(target, lp)) {
            return gaugeConnector;
        }
        try resolver.poolInfo(target) returns (CurveLiquidityPool memory pool) {
            return poolConnectors[pool.kind];
        } catch { }
        return address(0);
    }
}
