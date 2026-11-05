// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { RamsesHyperEvmV2GaugeConnector } from
    "contracts/connectors/ramses/RamsesHyperEvmV2GaugeConnector.sol";

contract RamsesHyperEvmGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    RamsesHyperEvmV2GaugeConnector public immutable
        ramsesHyperEvmV2GaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        RamsesHyperEvmV2GaugeConnector ramsesHyperEvmV2GaugeConnector_
    ) {
        voter = voter_;
        ramsesHyperEvmV2GaugeConnector = ramsesHyperEvmV2GaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            return address(ramsesHyperEvmV2GaugeConnector);
        }

        return address(0);
    }
}
