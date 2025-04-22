// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { VelodromeGaugeConnector } from
    "contracts/connectors/velodrome/VelodromeGaugeConnector.sol";

interface IStakingRewardsFactory {
    function poolForGauge(
        address gauge
    ) external view returns (address);
}

contract VelodromeStakingRewardsRegistry is ICustomConnectorRegistry {
    VelodromeGaugeConnector public immutable velodromeGaugeConnector;
    IStakingRewardsFactory public immutable stakingRewardsFactory;

    constructor(
        IStakingRewardsFactory stakingRewardsFactory_,
        VelodromeGaugeConnector velodromeGaugeConnector_
    ) {
        stakingRewardsFactory = stakingRewardsFactory_;
        velodromeGaugeConnector = velodromeGaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (stakingRewardsFactory.poolForGauge(target) != address(0)) {
            return address(velodromeGaugeConnector);
        }

        return address(0);
    }
}
