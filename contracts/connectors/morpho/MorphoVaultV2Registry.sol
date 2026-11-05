// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    MorphoVaultV2Connector
} from "contracts/connectors/morpho/MorphoVaultV2Connector.sol";

/// @notice One immutable protocol connector for authenticated factory vaults.
contract MorphoVaultV2Registry is ICustomConnectorRegistry {
    MorphoVaultV2Connector public immutable vaultConnector;

    constructor(
        MorphoVaultV2Connector connector_
    ) {
        if (address(connector_).code.length == 0) {
            revert MorphoVaultV2Connector.InvalidConfiguration();
        }
        vaultConnector = connector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        return
            vaultConnector.isVault(target)
                ? address(vaultConnector)
                : address(0);
    }
}
