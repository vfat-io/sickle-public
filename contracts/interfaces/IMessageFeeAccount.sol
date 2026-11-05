// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";

/// @notice Per-Sickle native balance that pays protocol messages to other
/// chains (MessageFeeAccount).
interface IMessageFeeAccount {
    /// @notice Credit `msg.value` to `sickle`'s balance.
    function deposit(
        Sickle sickle
    ) external payable;

    /// @notice Pay `amount` of `sickle`'s balance to the caller, a
    /// whitelisted Sickle caller, at most once per `interval` for `action`.
    function spend(
        Sickle sickle,
        uint256 amount,
        bytes32 action,
        uint256 interval
    ) external;

    function balanceOf(
        Sickle sickle
    ) external view returns (uint256);
}
