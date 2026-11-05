// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    VelodromeGaugeConnector
} from "contracts/connectors/velodrome/VelodromeGaugeConnector.sol";
import {
    SlipstreamGaugeConnector
} from "contracts/connectors/velodrome/SlipstreamGaugeConnector.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";

interface IIsPool {
    function isPool(
        address pool
    ) external view returns (bool);
}

contract SuperchainGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    IIsPool public immutable v2PoolFactory;
    IIsPool public immutable slipstreamPoolFactory;
    IIsPool public immutable slipstreamGaugesV2PoolFactory;
    VelodromeGaugeConnector public immutable v2GaugeConnector;
    SlipstreamGaugeConnector public immutable slipstreamGaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        IIsPool v2PoolFactory_,
        IIsPool slipstreamPoolFactory_,
        IIsPool slipstreamGaugesV2PoolFactory_,
        VelodromeGaugeConnector v2GaugeConnector_,
        SlipstreamGaugeConnector slipstreamGaugeConnector_
    ) {
        voter = voter_;
        v2PoolFactory = v2PoolFactory_;
        slipstreamPoolFactory = slipstreamPoolFactory_;
        slipstreamGaugesV2PoolFactory = slipstreamGaugesV2PoolFactory_;
        v2GaugeConnector = v2GaugeConnector_;
        slipstreamGaugeConnector = slipstreamGaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            address pool = voter.poolForGauge(target);
            if (v2PoolFactory.isPool(pool)) {
                return address(v2GaugeConnector);
            }
            if (
                _isPool(slipstreamPoolFactory, pool)
                    || _isPool(slipstreamGaugesV2PoolFactory, pool)
            ) {
                return address(slipstreamGaugeConnector);
            }
        }

        return address(0);
    }

    function _isPool(
        IIsPool factory,
        address pool
    ) internal view returns (bool) {
        return address(factory) != address(0) && factory.isPool(pool);
    }
}
