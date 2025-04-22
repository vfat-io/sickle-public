// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { FenixGaugeConnector } from
    "contracts/connectors/fenix/FenixGaugeConnector.sol";

interface IFenixPairFactory {
    function isPair(
        address pair
    ) external view returns (bool);
}

contract FenixGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    IFenixPairFactory public immutable v2PairFactory;
    FenixGaugeConnector public immutable v2GaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        IFenixPairFactory v2PairFactory_,
        FenixGaugeConnector v2GaugeConnector_
    ) {
        voter = voter_;
        v2PairFactory = v2PairFactory_;
        v2GaugeConnector = v2GaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            address pair = voter.poolForGauge(target);
            if (v2PairFactory.isPair(pair)) {
                return address(v2GaugeConnector);
            } else {
                return address(0);
            }
        } else {
            return address(0);
        }
    }
}
