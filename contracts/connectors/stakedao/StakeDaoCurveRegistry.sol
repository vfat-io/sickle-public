// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    StakeDaoCurveVaultConnector
} from "contracts/connectors/stakedao/StakeDaoCurveVaultConnector.sol";

/// @notice Resolves Stake DAO V2 Curve reward vaults to their farm connector.
/// @dev Vault validation lives in the connector, so routing and every
/// deposit, withdraw and claim check the same ProtocolController lookup. Any
/// vault the factory creates later resolves with no admin transaction.
contract StakeDaoCurveRegistry is ICustomConnectorRegistry {
    StakeDaoCurveVaultConnector public immutable vaultConnector;

    constructor(
        StakeDaoCurveVaultConnector vaultConnector_
    ) {
        vaultConnector = vaultConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        if (vaultConnector.isVault(target)) {
            return address(vaultConnector);
        }
        return address(0);
    }
}
