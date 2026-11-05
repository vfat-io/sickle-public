// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SickleRegistry } from "contracts/SickleRegistry.sol";

/// @dev The executing Sickle, seen from inside a `delegatecall`. `Multicall`
/// declares `registry` as an immutable public getter, so `address(this)`
/// answers it whenever this code runs in a Sickle's context.
interface IRegistryHolder {
    function registry() external view returns (SickleRegistry);
}

contract DelegateModule {
    /// @notice Thrown when a connector is not a whitelisted Sickle target.
    /// @dev Shares a signature, and therefore the selector 0x47ccabe7, with
    /// `Multicall.TargetNotWhitelisted`, so both refusals decode identically.
    error TargetNotWhitelisted(address target);

    function _delegateTo(
        address to,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory result) = to.delegatecall(data);

        if (!success) {
            if (result.length == 0) revert();
            assembly {
                revert(add(32, result), mload(result))
            }
        }

        return result;
    }

    /// @notice Delegatecall a connector resolved through `ConnectorRegistry`.
    /// @dev `connectorOf()` answers from a registry whose admin is a separate
    /// role from the one that curates `SickleRegistry`, so a connector reached
    /// this way would otherwise run in the Sickle's storage and balance context
    /// without ever passing the whitelist `Multicall` enforces on every other
    /// delegatecall target. Two registrations disagreeing is not hypothetical:
    /// retired aggregator connectors have been removed from the target
    /// whitelist while their `connectorOf` mapping stayed live, leaving the
    /// retirement with no effect on this path.
    ///
    /// The registry is read from the executing Sickle rather than held as an
    /// immutable, so the check always resolves to the same allowlist that
    /// authorised the enclosing `multicall`, and a redeployed library cannot
    /// drift from it. Outside a Sickle there is no `registry()` to answer and
    /// the call reverts, which is the safe direction.
    function _delegateToConnector(
        address connector,
        bytes memory data
    ) internal returns (bytes memory) {
        SickleRegistry registry = IRegistryHolder(address(this)).registry();

        if (!registry.isWhitelistedTarget(connector)) {
            revert TargetNotWhitelisted(connector);
        }

        return _delegateTo(connector, data);
    }
}
