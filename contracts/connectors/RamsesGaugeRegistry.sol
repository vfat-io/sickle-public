// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../ConnectorRegistry.sol";
import "./RamsesGaugeConnector.sol";
import "./RamsesV3Connector.sol";
import { IGaugeRegistryVoter } from "./GaugeRegistry.sol";
import { IGaugeV2 } from "../interfaces/external/ramses/IGaugeV2.sol";

interface IRamsesPairFactory {
    function isPair(address pair) external view returns (bool);
}

contract RamsesGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    RamsesGaugeConnector public immutable ramsesGaugeConnector;
    IRamsesPairFactory public immutable ramsesPairFactory;
    RamsesV3Connector public immutable ramsesV3Connector;
    address public immutable ramsesCLGaugeFactory;

    constructor(
        IGaugeRegistryVoter voter_,
        RamsesGaugeConnector ramsesGaugeConnector_,
        IRamsesPairFactory ramsesPairFactory_,
        RamsesV3Connector ramsesV3Connector_,
        address ramsesCLGaugeFactory_
    ) {
        voter = voter_;
        ramsesGaugeConnector = ramsesGaugeConnector_;
        ramsesPairFactory = ramsesPairFactory_;
        ramsesV3Connector = ramsesV3Connector_;
        ramsesCLGaugeFactory = ramsesCLGaugeFactory_;
    }

    function connectorOf(address target)
        external
        view
        override
        returns (address)
    {
        if (voter.isGauge(target)) {
            if (ramsesPairFactory.isPair(voter.poolForGauge(target))) {
                return address(ramsesGaugeConnector);
            }
            address gaugeFactory = IGaugeV2(target).gaugeFactory();
            if (gaugeFactory == ramsesCLGaugeFactory) {
                return address(ramsesV3Connector);
            }
        }

        return address(0);
    }
}
