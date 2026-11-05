// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IGaugeRegistryVoter } from "contracts/connectors/GaugeRegistry.sol";
import {
    HyperstableGaugeConnector
} from "contracts/connectors/hyperstable/HyperstableGaugeConnector.sol";
import {
    ICurveStableSwapFactory
} from "contracts/interfaces/external/curve/ICurveStableSwapFactory.sol";
import {
    IUniswapV2Factory
} from "contracts/interfaces/external/uniswap/IUniswapV2Factory.sol";
import {
    IUniswapV2Pair
} from "contracts/interfaces/external/uniswap/IUniswapV2Pair.sol";

/// @dev Hyperstable's Voter also lists gauges for MetaMorpho V1 vaults, which
/// Sickle does not support. A gauge resolves only when the Voter recognises it
/// and its pool is a Curve StableSwap-NG factory pool or a HyperSwap V2
/// factory pair. Killed gauges still resolve so positions can exit.
contract HyperstableGaugeRegistry is ICustomConnectorRegistry {
    IGaugeRegistryVoter public immutable voter;
    ICurveStableSwapFactory public immutable curveStableSwapFactory;
    IUniswapV2Factory public immutable hyperswapV2Factory;
    HyperstableGaugeConnector public immutable gaugeConnector;

    constructor(
        IGaugeRegistryVoter voter_,
        ICurveStableSwapFactory curveStableSwapFactory_,
        IUniswapV2Factory hyperswapV2Factory_,
        HyperstableGaugeConnector gaugeConnector_
    ) {
        voter = voter_;
        curveStableSwapFactory = curveStableSwapFactory_;
        hyperswapV2Factory = hyperswapV2Factory_;
        gaugeConnector = gaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (voter.isGauge(target)) {
            address pool = voter.poolForGauge(target);
            if (
                curveStableSwapFactory.get_n_coins(pool) > 0
                    || _isHyperswapV2Pair(pool)
            ) {
                return address(gaugeConnector);
            }
        }

        return address(0);
    }

    /// @dev Round-trips the pool's tokens through the factory. Vaults and
    /// Curve pools have no `token0()`, so those calls are caught rather than
    /// reverting the lookup.
    function _isHyperswapV2Pair(
        address pool
    ) internal view returns (bool) {
        try IUniswapV2Pair(pool).token0() returns (address token0) {
            try IUniswapV2Pair(pool).token1() returns (address token1) {
                return hyperswapV2Factory.getPair(token0, token1) == pool;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
