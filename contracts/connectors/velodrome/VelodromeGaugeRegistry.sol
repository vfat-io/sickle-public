// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { VelodromeGaugeConnector } from
    "contracts/connectors/velodrome/VelodromeGaugeConnector.sol";
import { SlipstreamGaugeConnector } from
    "contracts/connectors/velodrome/SlipstreamGaugeConnector.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";

interface IPairFactory {
    function isPair(
        address pair
    ) external view returns (bool);
}

contract VelodromeGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    IPairFactory public immutable v2PairFactory;
    IPairFactory public immutable deprecatedSlipstreamPairFactory;
    IPairFactory public immutable slipstreamPairFactory;
    VelodromeGaugeConnector public immutable v2GaugeConnector;
    SlipstreamGaugeConnector public immutable slipstreamGaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        IPairFactory v2PairFactory_,
        IPairFactory deprecatedSlipstreamPairFactory_,
        IPairFactory slipstreamPairFactory_,
        VelodromeGaugeConnector v2GaugeConnector_,
        SlipstreamGaugeConnector slipstreamGaugeConnector_
    ) {
        voter = voter_;
        v2PairFactory = v2PairFactory_;
        deprecatedSlipstreamPairFactory = deprecatedSlipstreamPairFactory_;
        slipstreamPairFactory = slipstreamPairFactory_;
        v2GaugeConnector = v2GaugeConnector_;
        slipstreamGaugeConnector = slipstreamGaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            address pair = voter.poolForGauge(target);
            if (v2PairFactory.isPair(pair)) {
                return address(v2GaugeConnector);
            }
            if (
                address(deprecatedSlipstreamPairFactory) != address(0)
                    && deprecatedSlipstreamPairFactory.isPair(pair)
                    || slipstreamPairFactory.isPair(pair)
            ) {
                return address(slipstreamGaugeConnector);
            }
        }

        return address(0);
    }
}
