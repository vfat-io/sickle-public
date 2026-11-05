// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SickleFactory, Sickle } from "contracts/SickleFactory.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { AccessControlModule } from "contracts/modules/AccessControlModule.sol";

contract StrategyModule is AccessControlModule {
    ConnectorRegistry public immutable connectorRegistry;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry_
    ) AccessControlModule(factory) {
        connectorRegistry = connectorRegistry_;
    }

    function getSickle(
        address owner
    ) public view returns (Sickle) {
        Sickle sickle = Sickle(payable(factory.sickles(owner)));
        if (address(sickle) == address(0)) {
            revert SickleNotDeployed();
        }
        return sickle;
    }

    /// @dev Kept `internal` so a strategy contract cannot be used as a
    /// public relay into `SickleFactory.getOrDeploy` with caller-chosen
    /// `(owner, approved, referralCode)`. The vulnerability was that any
    /// external caller could pre-seed a victim's deterministic Sickle with
    /// an attacker as the `approved` automator, then keep that role
    /// permanently because subsequent calls return the existing Sickle
    /// without updating `approved`. Strategies that need to resolve a Sickle
    /// during their own external entrypoint still use `msg.sender` as the
    /// owner and remain unaffected.
    function getOrDeploySickle(
        address owner,
        address approved,
        bytes32 referralCode
    ) internal returns (Sickle) {
        return
            Sickle(payable(factory.getOrDeploy(owner, approved, referralCode)));
    }
}
