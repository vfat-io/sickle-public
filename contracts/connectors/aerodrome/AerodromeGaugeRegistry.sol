// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { AerodromeGaugeConnector } from
    "contracts/connectors/aerodrome/AerodromeGaugeConnector.sol";
import { SlipstreamGaugeConnector } from
    "contracts/connectors/velodrome/SlipstreamGaugeConnector.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { ICLPoolFactory } from
    "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";
import { IV2PoolFactory } from
    "contracts/interfaces/external/aerodrome/IV2PoolFactory.sol";

contract AerodromeGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    IV2PoolFactory public immutable v2PoolFactory;
    ICLPoolFactory public immutable slipstreamPoolFactory;
    AerodromeGaugeConnector public immutable v2GaugeConnector;
    SlipstreamGaugeConnector public immutable slipstreamGaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        IV2PoolFactory v2PoolFactory_,
        ICLPoolFactory slipstreamPoolFactory_,
        AerodromeGaugeConnector v2GaugeConnector_,
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
