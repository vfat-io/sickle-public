// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Provenance views shared by every Balancer V3 `BasePoolFactory`
/// (WeightedPoolFactory, StablePoolFactory).
interface IBalancerV3PoolFactory {
    function getVault() external view returns (address);

    function isPoolFromFactory(
        address pool
    ) external view returns (bool);
}
