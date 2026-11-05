// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IFPMMFactory } from "contracts/interfaces/external/mento/IFPMM.sol";
import {
    IMentoRouter
} from "contracts/interfaces/external/mento/IMentoRouter.sol";

/// @notice Resolves FPMM pools of the Mento Router's default factory to
/// `connector`, so a held LP (whose `Farm.stakingContract` is the pool) works
/// with the `Farm`-addressed strategies. The factory, not a pool list, vouches
/// for each pool, the same binding `MentoFPMMConnector` uses for liquidity.
contract MentoFPMMPoolRegistry is ICustomConnectorRegistry {
    IFPMMFactory public immutable factory;
    address public immutable connector;

    constructor(
        IMentoRouter router,
        address connector_
    ) {
        factory = IFPMMFactory(router.defaultFactory());
        connector = connector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        return factory.isPool(target) ? connector : address(0);
    }
}
