// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";

contract AccessControlModule {
    SickleFactory public immutable factory;

    error NotOwner(address sender); // 30cd7471
    error NotApproved();
    error SickleNotDeployed();
    error NotRegisteredSickle();

    constructor(
        SickleFactory factory_
    ) {
        factory = factory_;
    }

    modifier onlyRegisteredSickle() {
        if (factory.admins(address(this)) == address(0)) {
            revert NotRegisteredSickle();
        }

        _;
    }

    // @dev allow access only to the sickle's owner or addresses approved by him
    // to use only for functions such as claiming rewards or compounding rewards
    modifier onlyApproved(
        Sickle sickle
    ) {
        // Here we check if the Sickle was really deployed, this gives use the
        // guarantee that the contract that we are going to call is genuine
        if (factory.admins(address(sickle)) == address(0)) {
            revert SickleNotDeployed();
        }

        if (sickle.approved() != msg.sender) revert NotApproved();

        _;
    }

    /// @dev Same check as `onlyApproved`, as a function. A modifier body is
    /// inlined at every use; a strategy near the EIP-170 limit with several
    /// `*For` entrypoints can wrap this in a one-line modifier instead and
    /// pay one copy. Kept separate from `onlyApproved` so strategies that
    /// keep using the modifier do not change bytecode.
    function _requireApproved(
        Sickle sickle
    ) internal view {
        if (factory.admins(address(sickle)) == address(0)) {
            revert SickleNotDeployed();
        }
        if (sickle.approved() != msg.sender) revert NotApproved();
    }
}
