// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { SwapxGaugeConnector } from
    "contracts/connectors/swapx/SwapxGaugeConnector.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";

contract SwapxGaugeRegistry is ICustomConnectorRegistry {
    SwapxGaugeConnector public immutable swapxGaugeConnector;
    IGaugeRegistryVoter public immutable voter;

    constructor(
        SwapxGaugeConnector swapxGaugeConnector_,
        IGaugeRegistryVoter voter_
    ) {
        voter = voter_;
        swapxGaugeConnector = swapxGaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            return address(swapxGaugeConnector);
        } else {
            return address(0);
        }
    }
}
