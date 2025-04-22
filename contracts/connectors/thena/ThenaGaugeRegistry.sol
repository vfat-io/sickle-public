// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { ThenaGaugeConnector } from
    "contracts/connectors/thena/ThenaGaugeConnector.sol";
import { ICLPoolFactory } from
    "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";

interface IThenaPairFactory {
    function isPair(
        address pair
    ) external view returns (bool);
}

contract ThenaGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    IThenaPairFactory public immutable v2PairFactory;
    ThenaGaugeConnector public immutable v2GaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        IThenaPairFactory v2PairFactory_,
        ThenaGaugeConnector v2GaugeConnector_
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
