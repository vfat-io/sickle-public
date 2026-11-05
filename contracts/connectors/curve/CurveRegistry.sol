// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    ICurveXChainLiquidityGaugeFactory
} from "contracts/interfaces/external/curve/ICurveXChainLiquidityGaugeFactory.sol";
import {
    ICurveStableSwapFactory
} from "contracts/interfaces/external/curve/ICurveStableSwapFactory.sol";
import {
    CurvePoolConnector
} from "contracts/connectors/curve/CurvePoolConnector.sol";
import {
    CurveGaugeConnector
} from "contracts/connectors/curve/CurveGaugeConnector.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";

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

        if (_isPoolFactoryGauge(target)) {
            return address(gaugeConnector);
        }

        return address(0);
    }

    /// @dev A gauge the StableSwap factory deployed itself is never recorded in
    /// the liquidity gauge factory, so `is_valid_gauge` misses it -- on
    /// Ethereum that is every gauge these pools have. Confirm such a candidate
    /// by
    /// round-tripping it through the pool factory: read the candidate's
    /// `lp_token()` and require the factory to name this exact address as that
    /// pool's gauge. Both legs are staticcalled and length-checked, so a target
    /// that is not a gauge at all fails to match rather than reverting
    /// `connectorOf` for every other lookup.
    function _isPoolFactoryGauge(
        address target
    ) internal view returns (bool) {
        (bool ok, bytes memory data) = target.staticcall(
            abi.encodeWithSelector(ICurveGauge.lp_token.selector)
        );
        if (!ok || data.length != 32) {
            return false;
        }

        address lpToken = abi.decode(data, (address));
        // Guard the zero case explicitly: `get_gauge` of an unknown pool is
        // also zero, so without this a target reporting no LP token would
        // match on 0 == 0.
        if (lpToken == address(0)) {
            return false;
        }

        (ok, data) = address(poolFactory)
            .staticcall(
                abi.encodeWithSelector(
                    ICurveStableSwapFactory.get_gauge.selector, lpToken
                )
            );
        if (!ok || data.length != 32) {
            return false;
        }

        return abi.decode(data, (address)) == target;
    }
}
