// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import { ICLPoolFactory } from
    "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";
import { INFPG } from "contracts/interfaces/external/equalizer/INFPG.sol";

/// @title Registry for Equalizer NFPG (Non-Fungible Position Gauge) connectors
/// @notice Identifies NFPG gauges by verifying their pool reference against the
/// Thick factory and that their underlying gauge is recognised by the voter.
contract EqualizerNfpgGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    ICLPoolFactory public immutable factory;
    address public immutable connector;

    constructor(
        IGaugeRegistryVoter voter_,
        ICLPoolFactory factory_,
        address connector_
    ) {
        voter = voter_;
        factory = factory_;
        connector = connector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        // Probe the target for NFPG-specific view functions
        (bool s0, bytes memory d0) =
            target.staticcall(abi.encodeWithSelector(INFPG.pool.selector));
        (bool s1, bytes memory d1) =
            target.staticcall(abi.encodeWithSelector(INFPG.token0.selector));
        (bool s2, bytes memory d2) =
            target.staticcall(abi.encodeWithSelector(INFPG.token1.selector));
        (bool s3, bytes memory d3) = target.staticcall(
            abi.encodeWithSelector(INFPG.tickSpacing.selector)
        );
        (bool s4, bytes memory d4) =
            target.staticcall(abi.encodeWithSelector(INFPG.gauge.selector));

        if (
            !s0 || !s1 || !s2 || !s3 || !s4 || d0.length < 32
                || d1.length < 32 || d2.length < 32 || d3.length < 32
                || d4.length < 32
        ) return address(0);

        address pool = abi.decode(d0, (address));
        address token0 = abi.decode(d1, (address));
        address token1 = abi.decode(d2, (address));
        int24 tickSpacing = abi.decode(d3, (int24));
        address gauge = abi.decode(d4, (address));

        // Factory round-trip: verify the pool is a real Thick pool
        if (factory.getPool(token0, token1, tickSpacing) != pool) {
            return address(0);
        }

        // Verify the underlying gauge is recognised by the voter
        if (!voter.isGauge(gauge)) return address(0);

        return connector;
    }
}
