// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { Sickle } from "contracts/Sickle.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { SickleRegistry } from "contracts/SickleRegistry.sol";
import {
    IMessageFeeAccount
} from "contracts/interfaces/IMessageFeeAccount.sol";

/// @title MessageFeeAccount
/// @notice Holds per-Sickle native balances that pay protocol messages to
/// other chains, such as remote votes and claims, spent by the strategies
/// the SickleRegistry whitelists as Sickle callers.
/// @dev Kept apart from the strategies, which hold no state, so balances and
/// spend intervals survive a strategy redeploy. A whitelisted caller can
/// already drive every Sickle, so spending its fee balance adds no trust,
/// and whitelisting a new strategy is its only authorization.
contract MessageFeeAccount is IMessageFeeAccount {
    /// ERRORS ///
    error InvalidSickle();
    error NotSickleOwner();
    error NotWhitelistedCaller(address caller);
    error InsufficientBalance(uint256 amount, uint256 balance);
    error SpendTooSoon(uint256 nextAt);

    /// EVENTS ///

    event Deposited(
        Sickle indexed sickle, address indexed depositor, uint256 amount
    );
    event Withdrawn(Sickle indexed sickle, uint256 amount);
    event Spent(
        Sickle indexed sickle,
        address indexed spender,
        bytes32 indexed action,
        uint256 amount
    );

    /// STORAGE ///

    SickleFactory public immutable factory;
    SickleRegistry public immutable registry;

    mapping(Sickle => uint256) public override balanceOf;

    mapping(Sickle => mapping(bytes32 => uint256)) public lastSpentAt;

    constructor(
        SickleFactory factory_
    ) {
        factory = factory_;
        registry = factory_.registry();
    }

    /// @notice Permissionlessly top up a Sickle's balance.
    function deposit(
        Sickle sickle
    ) external payable override {
        if (factory.admins(address(sickle)) == address(0)) {
            revert InvalidSickle();
        }
        balanceOf[sickle] += msg.value;
        emit Deposited(sickle, msg.sender, msg.value);
    }

    /// @notice Withdraw `amount` of a Sickle's balance to its owner.
    /// @custom:access Restricted to the Sickle owner.
    function withdraw(
        Sickle sickle,
        uint256 amount
    ) external {
        if (factory.admins(address(sickle)) != msg.sender) {
            revert NotSickleOwner();
        }
        _debit(sickle, amount);
        emit Withdrawn(sickle, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    /// @custom:access Restricted to whitelisted Sickle callers.
    function spend(
        Sickle sickle,
        uint256 amount,
        bytes32 action,
        uint256 interval
    ) external override {
        if (!registry.isWhitelistedCaller(msg.sender)) {
            revert NotWhitelistedCaller(msg.sender);
        }
        uint256 nextAt = lastSpentAt[sickle][action] + interval;
        if (block.timestamp < nextAt) revert SpendTooSoon(nextAt);
        lastSpentAt[sickle][action] = block.timestamp;
        _debit(sickle, amount);
        emit Spent(sickle, msg.sender, action, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    function _debit(
        Sickle sickle,
        uint256 amount
    ) private {
        uint256 balance = balanceOf[sickle];
        if (amount > balance) revert InsufficientBalance(amount, balance);
        balanceOf[sickle] = balance - amount;
    }
}
