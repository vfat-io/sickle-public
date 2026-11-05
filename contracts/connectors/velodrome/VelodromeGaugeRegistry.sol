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
    IPairFactory public immutable slipstreamGaugesV2PairFactory;
    VelodromeGaugeConnector public immutable v2GaugeConnector;
    SlipstreamGaugeConnector public immutable slipstreamGaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        IPairFactory v2PairFactory_,
        IPairFactory deprecatedSlipstreamPairFactory_,
        IPairFactory slipstreamPairFactory_,
        IPairFactory slipstreamGaugesV2PairFactory_,
        VelodromeGaugeConnector v2GaugeConnector_,
        SlipstreamGaugeConnector slipstreamGaugeConnector_
    ) {
        voter = voter_;
        v2PairFactory = v2PairFactory_;
        deprecatedSlipstreamPairFactory = deprecatedSlipstreamPairFactory_;
        slipstreamPairFactory = slipstreamPairFactory_;
        slipstreamGaugesV2PairFactory = slipstreamGaugesV2PairFactory_;
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
                _isPair(deprecatedSlipstreamPairFactory, pair)
                    || _isPair(slipstreamPairFactory, pair)
                    || _isPair(slipstreamGaugesV2PairFactory, pair)
            ) {
                return address(slipstreamGaugeConnector);
            }
        }

        return address(0);
    }

    function _isPair(
        IPairFactory factory,
        address pair
    ) internal view returns (bool) {
        return address(factory) != address(0) && factory.isPair(pair);
    }
}
