// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { SlipstreamGaugeConnector } from
    "contracts/connectors/velodrome/SlipstreamGaugeConnector.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { ICLPoolFactory } from
    "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";

contract DeprecatedAerodromeGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    ICLPoolFactory public immutable slipstreamPairFactory;
    SlipstreamGaugeConnector public immutable slipstreamGaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        ICLPoolFactory slipstreamPairFactory_,
        SlipstreamGaugeConnector slipstreamGaugeConnector_
    ) {
        voter = voter_;
        slipstreamPairFactory = slipstreamPairFactory_;
        slipstreamGaugeConnector = slipstreamGaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            address pair = voter.poolForGauge(target);
            if (slipstreamPairFactory.isPool(pair)) {
                return address(slipstreamGaugeConnector);
            }
        }

        return address(0);
    }
}
