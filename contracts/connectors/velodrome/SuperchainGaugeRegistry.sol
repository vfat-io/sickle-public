// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { VelodromeGaugeConnector } from
    "contracts/connectors/velodrome/VelodromeGaugeConnector.sol";
import { SlipstreamGaugeConnector } from
    "contracts/connectors/velodrome/SlipstreamGaugeConnector.sol";
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
    VelodromeGaugeConnector public immutable v2GaugeConnector;
    SlipstreamGaugeConnector public immutable slipstreamGaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        IIsPool v2PoolFactory_,
        IIsPool slipstreamPoolFactory_,
        VelodromeGaugeConnector v2GaugeConnector_,
        SlipstreamGaugeConnector slipstreamGaugeConnector_
    ) {
        voter = voter_;
        v2PoolFactory = v2PoolFactory_;
        slipstreamPoolFactory = slipstreamPoolFactory_;
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
            if (slipstreamPoolFactory.isPool(pool)) {
                return address(slipstreamGaugeConnector);
            }
        }

        return address(0);
    }
}
