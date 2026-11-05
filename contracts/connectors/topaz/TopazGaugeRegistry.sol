// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    TopazGaugeConnector
} from "contracts/connectors/topaz/TopazGaugeConnector.sol";
import {
    SlipstreamGaugeConnector
} from "contracts/connectors/velodrome/SlipstreamGaugeConnector.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import {
    ICLPoolFactory
} from "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";
import {
    IV2PoolFactory
} from "contracts/interfaces/external/aerodrome/IV2PoolFactory.sol";

contract TopazGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    IV2PoolFactory public immutable v2PoolFactory;
    ICLPoolFactory public immutable slipstreamPoolFactory;
    TopazGaugeConnector public immutable v2GaugeConnector;
    SlipstreamGaugeConnector public immutable slipstreamGaugeConnector;

    constructor(
        IGaugeRegistryVoter _voter,
        IV2PoolFactory _v2PoolFactory,
        ICLPoolFactory _slipstreamPoolFactory,
        TopazGaugeConnector _v2GaugeConnector,
        SlipstreamGaugeConnector _slipstreamGaugeConnector
    ) {
        voter = _voter;
        v2PoolFactory = _v2PoolFactory;
        slipstreamPoolFactory = _slipstreamPoolFactory;
        v2GaugeConnector = _v2GaugeConnector;
        slipstreamGaugeConnector = _slipstreamGaugeConnector;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            address pair = voter.poolForGauge(target);
            if (v2PoolFactory.isPool(pair)) {
                return address(v2GaugeConnector);
            }
            if (slipstreamPoolFactory.isPool(pair)) {
                return address(slipstreamGaugeConnector);
            }
        }
        return address(0);
    }
}
