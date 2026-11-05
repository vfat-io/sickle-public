// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    IBalancerV3PoolFactory
} from "contracts/interfaces/external/balancer/v3/IBalancerV3PoolFactory.sol";

/// @notice Resolves Balancer V3 pools created by either weighted or stable pool
/// factory to `connector`, so unstaked BPT positions (whose
/// `Farm.stakingContract` is the pool) work with the `Farm`-addressed
/// strategies. Pools are created permissionlessly, so they cannot be
/// registered one by one.
contract BalancerV3PoolRegistry is ICustomConnectorRegistry {
    IBalancerV3PoolFactory public immutable weightedPoolFactory;
    IBalancerV3PoolFactory public immutable stablePoolFactory;
    address public immutable connector;

    constructor(
        IBalancerV3PoolFactory weightedPoolFactory_,
        IBalancerV3PoolFactory stablePoolFactory_,
        address connector_
    ) {
        weightedPoolFactory = weightedPoolFactory_;
        stablePoolFactory = stablePoolFactory_;
        connector = connector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (
            weightedPoolFactory.isPoolFromFactory(target)
                || stablePoolFactory.isPoolFromFactory(target)
        ) {
            return connector;
        }
        return address(0);
    }
}
