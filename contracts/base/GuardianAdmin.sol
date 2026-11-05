// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Admin } from "contracts/base/Admin.sol";

/// @title GuardianAdmin
/// @author vfat.tools
/// @notice Extends Admin with an optional guardian that can perform
/// emergency disable-only actions on inheriting bridge contracts.
abstract contract GuardianAdmin is Admin {
    /// ERRORS ///

    /// @notice Thrown when the caller is neither guardian nor admin
    error NotGuardianOrAdminError();

    /// EVENTS ///

    /// @notice Emitted when a new guardian is set
    /// @param oldGuardian Address of the old guardian
    /// @param newGuardian Address of the new guardian
    event GuardianSet(address oldGuardian, address newGuardian);

    /// STORAGE ///

    /// @notice Address of the current emergency guardian
    address public guardian;

    /// MODIFIERS ///

    /// @dev Restricts a function to the guardian or admin
    modifier onlyGuardianOrAdmin() {
        _onlyGuardianOrAdmin();
        _;
    }

    constructor(
        address admin_,
        address guardian_
    ) Admin(admin_) {
        if (guardian_ != address(0)) {
            emit GuardianSet(address(0), guardian_);
            guardian = guardian_;
        }
    }

    /// @notice Sets a new guardian
    /// @param newGuardian Address of the new guardian
    /// @custom:access Restricted to protocol admin.
    function setGuardian(
        address newGuardian
    ) external onlyAdmin {
        if (newGuardian == guardian) return;
        emit GuardianSet(guardian, newGuardian);
        guardian = newGuardian;
    }

    function _onlyGuardianOrAdmin() internal view {
        if (msg.sender != guardian && msg.sender != admin) {
            revert NotGuardianOrAdminError();
        }
    }
}
