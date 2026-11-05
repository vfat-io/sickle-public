// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    IAeroFactoryRegistry
} from "contracts/interfaces/external/aero/IAeroFactoryRegistry.sol";
import {
    IAeroPool,
    AERO_V2_STABLE,
    AERO_V2_VOLATILE,
    AERO_CL
} from "contracts/interfaces/external/aero/IAeroPool.sol";
import {
    AeroPoolConnector
} from "contracts/connectors/aero/AeroPoolConnector.sol";
import {
    AeroGaugeConnector
} from "contracts/connectors/aero/AeroGaugeConnector.sol";
import {
    AeroClGaugeConnector
} from "contracts/connectors/aero/AeroClGaugeConnector.sol";

/// @notice Resolves only pools and gauges permanently recorded by Aero's
/// FactoryRegistry. VotingRewardsManager contracts deliberately resolve to
/// zero: they are veNFT voting positions, not LP farms.
contract AeroConnectorRegistry is ICustomConnectorRegistry {
    IAeroFactoryRegistry public immutable factoryRegistry;
    AeroPoolConnector public immutable poolConnector;
    AeroGaugeConnector public immutable gaugeConnector;
    AeroClGaugeConnector public immutable clGaugeConnector;

    error ZeroAddress();

    constructor(
        IAeroFactoryRegistry factoryRegistry_,
        AeroPoolConnector poolConnector_,
        AeroGaugeConnector gaugeConnector_,
        AeroClGaugeConnector clGaugeConnector_
    ) {
        if (
            address(factoryRegistry_) == address(0)
                || address(poolConnector_) == address(0)
                || address(gaugeConnector_) == address(0)
                || address(clGaugeConnector_) == address(0)
        ) {
            revert ZeroAddress();
        }
        factoryRegistry = factoryRegistry_;
        poolConnector = poolConnector_;
        gaugeConnector = gaugeConnector_;
        clGaugeConnector = clGaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (factoryRegistry.targetToFactory(target) != address(0)) {
            bytes32 targetPoolType = _poolType(target);
            if (_isV2(targetPoolType)) {
                return address(poolConnector);
            }
            // CL liquidity is addressed through its NFT manager, which is
            // configured directly in ConnectorRegistry.
            return address(0);
        }

        address pool = factoryRegistry.gaugeToTarget(target);
        if (pool == address(0)) {
            return address(0);
        }

        bytes32 poolType = _poolType(pool);
        if (_isV2(poolType)) {
            return address(gaugeConnector);
        }
        if (poolType == AERO_CL) {
            return address(clGaugeConnector);
        }
        return address(0);
    }

    function _poolType(
        address pool
    ) private view returns (bytes32 poolType) {
        try IAeroPool(pool).POOL_TYPE() returns (bytes32 result) {
            poolType = result;
        } catch { }
    }

    function _isV2(
        bytes32 poolType
    ) private pure returns (bool) {
        return poolType == AERO_V2_STABLE || poolType == AERO_V2_VOLATILE;
    }
}
