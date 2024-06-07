// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./base/Admin.sol";
import "./base/NonDelegateMulticall.sol";

contract Compounder is Admin, NonDelegateMulticall {
    error NotApprovedCompounder();

    event ApprovedCompounderSet(address approvedCompounder);
    event CompoundedFor(address[] targets);

    address payable public approvedCompounder;

    constructor(
        SickleRegistry registry_,
        address payable approvedCompounder_,
        address admin_
    ) Admin(admin_) NonDelegateMulticall(registry_) {
        approvedCompounder = approvedCompounder_;
    }

    modifier onlyApprovedCompounder() {
        if (msg.sender != approvedCompounder) revert NotApprovedCompounder();
        _;
    }

    /// @notice Update approved compounder address.
    /// @dev Controls which external address is allowed to
    /// compound farming positions for Sickles. This is expected to be the EOA
    /// of a compounder bot.
    /// @custom:access Restricted to protocol admin.
    function setApprovedCompounder(address payable approvedCompounder_)
        external
        onlyAdmin
    {
        approvedCompounder = approvedCompounder_;
        emit ApprovedCompounderSet(approvedCompounder_);
    }

    function compoundFor(
        address[] memory targets,
        bytes[] memory data
    ) external onlyApprovedCompounder {
        this.multicall(targets, data);
        emit CompoundedFor(targets);
    }

    receive() external payable { }
}
