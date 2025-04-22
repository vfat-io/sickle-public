// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IKodiakIslandPoolFactory } from
    "contracts/interfaces/external/kodiak/IKodiakIslandPoolFactory.sol";
import { IKodiakRewardVaultFactory } from
    "contracts/interfaces/external/kodiak/IKodiakRewardVaultFactory.sol";
import { IKodiakIslandPool } from
    "contracts/interfaces/external/kodiak/IKodiakIslandPool.sol";
import { KodiakIslandConnector } from
    "contracts/connectors/kodiak/KodiakIslandConnector.sol";
import { KodiakGaugeConnector } from
    "contracts/connectors/kodiak/KodiakGaugeConnector.sol";
import { IKodiakRewardVault } from
    "contracts/interfaces/external/kodiak/IKodiakRewardVault.sol";

contract KodiakRegistry is ICustomConnectorRegistry {
    IKodiakIslandPoolFactory public immutable islandPoolFactory;
    IKodiakRewardVaultFactory public immutable kodiakRewardVaultFactory;
    KodiakIslandConnector public immutable kodiakIslandConnector;
    KodiakGaugeConnector public immutable kodiakGaugeConnector;

    constructor(
        IKodiakIslandPoolFactory _islandPoolFactory,
        IKodiakRewardVaultFactory _kodiakRewardVaultFactory,
        KodiakIslandConnector _kodiakIslandConnector,
        KodiakGaugeConnector _kodiakGaugeConnector
    ) {
        islandPoolFactory = _islandPoolFactory;
        kodiakRewardVaultFactory = _kodiakRewardVaultFactory;
        kodiakIslandConnector = _kodiakIslandConnector;
        kodiakGaugeConnector = _kodiakGaugeConnector;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        (bool success, bytes memory result) = target.staticcall(
            abi.encodeWithSelector(IKodiakRewardVault.stakeToken.selector)
        );
        if (success && result.length == 32) {
            address stakeToken = abi.decode(result, (address));
            if (kodiakRewardVaultFactory.getVault(stakeToken) == target) {
                return address(kodiakGaugeConnector);
            }
        }
        (success, result) = target.staticcall(
            abi.encodeWithSelector(IKodiakIslandPool.manager.selector)
        );
        if (success && result.length == 32) {
            address manager = abi.decode(result, (address));
            address[] memory islands = islandPoolFactory.getIslands(manager);
            for (uint256 i = 0; i < islands.length; i++) {
                if (islands[i] == target) {
                    return address(kodiakIslandConnector);
                }
            }
        }
        return address(0);
    }
}
