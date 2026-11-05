// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { Sickle } from "contracts/Sickle.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { Admin } from "contracts/base/Admin.sol";

/// @title GasAccount
/// @notice Holds prepaid native-token balances for Sickle automation gas.
contract GasAccount is Admin {
    /// ERRORS ///
    error InvalidSickle();
    error InvalidRecipient();
    error NotSickleOwner();
    error NotAuthorizedCharger(address caller);
    error ChargeExceedsMaxChargeableFee(uint256 amount, uint256 max);
    error InsufficientGasAccountBalance(uint256 amount, uint256 balance);
    error ChargeCadenceIntervalNotSet(Sickle sickle, uint256 permission);
    error ChargeCadenceNotElapsed(
        Sickle sickle,
        uint256 permission,
        uint256 nextRunAt,
        uint256 timestamp
    );

    /// EVENTS ///

    event Deposited(
        Sickle indexed sickle, address indexed depositor, uint256 amount
    );
    event Withdrawn(Sickle indexed sickle, address indexed to, uint256 amount);
    event MaxChargeableFeeSet(Sickle indexed sickle, uint256 max);
    event AuthorizedChargerSet(address indexed charger, bool authorized);
    event TransactionCostCharged(address recipient, uint256 amount);
    event CadenceRequiredSet(uint256 indexed permission, bool required);
    event MinChargeIntervalSet(
        Sickle indexed sickle, uint256 indexed permission, uint32 interval
    );
    event ChargeCadenceRecorded(
        Sickle indexed sickle, uint256 indexed permission, uint64 timestamp
    );

    /// STORAGE ///

    SickleFactory public immutable factory;

    mapping(Sickle => uint256) public balances;

    /// @notice Per-Sickle ceiling on the native-token amount a single
    /// automation op may charge. A zero cap (the default) means the Sickle
    /// has NOT opted into gas-account mode: `charge` reverts and `Automation`
    /// falls back to fee mode. The owner sets a non-zero cap to enable
    /// gas-account automation — which both opts in and bounds the per-op
    /// spend, so a gas-price spike cannot drain the prepaid balance.
    mapping(Sickle => uint256) public maxChargeableFee;

    mapping(address => bool) public authorizedCharger;

    /// @notice Protocol-level switch requiring a per-Sickle minimum interval
    /// before a permission can charge the prepaid account.
    mapping(uint256 => bool) public cadenceRequired;

    /// @notice Owner-selected minimum seconds between charged ops for a
    /// permission. Zero means unset; if `cadenceRequired[permission]` is true,
    /// charging that permission reverts until the owner sets a non-zero value.
    mapping(Sickle => mapping(uint256 => uint32)) public minChargeInterval;

    /// @notice Last successful gas-account charge timestamp per Sickle and
    /// permission.
    mapping(Sickle => mapping(uint256 => uint64)) public lastChargedAt;

    constructor(
        SickleFactory factory_,
        address admin_
    ) Admin(admin_) {
        factory = factory_;
    }

    /// @notice Permissionlessly top up a Sickle's prepaid gas balance.
    function deposit(
        Sickle sickle
    ) external payable {
        _validateSickle(sickle);

        balances[sickle] += msg.value;

        emit Deposited(sickle, msg.sender, msg.value);
    }

    /// @notice Withdraw prepaid gas funds from a Sickle account.
    /// @custom:access Restricted to the Sickle owner.
    function withdraw(
        Sickle sickle,
        uint256 amount,
        address to
    ) external {
        _validateSickle(sickle);
        _onlySickleOwner(sickle);
        if (to == address(0)) revert InvalidRecipient();

        uint256 balance = balances[sickle];
        if (amount > balance) {
            revert InsufficientGasAccountBalance(amount, balance);
        }

        balances[sickle] = balance - amount;
        SafeTransferLib.safeTransferETH(to, amount);

        emit Withdrawn(sickle, to, amount);
    }

    /// @notice Set the maximum native-token amount a single automation op may
    /// charge for a Sickle. A non-zero cap opts the Sickle into gas-account
    /// mode; a zero cap (the default) disables it, leaving the Sickle in fee
    /// mode.
    /// @dev The cap is the owner's "peace of mind" guard: an op whose metered
    /// cost exceeds it reverts in `charge` instead of draining the balance, so
    /// a gas-price spike cannot blow out a funded account on a single op.
    /// @custom:access Restricted to the Sickle owner.
    function setMaxChargeableFee(
        Sickle sickle,
        uint256 max
    ) external {
        _validateSickle(sickle);
        _onlySickleOwner(sickle);

        maxChargeableFee[sickle] = max;

        emit MaxChargeableFeeSet(sickle, max);
    }

    /// @notice Set the minimum seconds between charged automation ops for a
    /// permission. Required only when the protocol marks that permission as
    /// cadence-gated.
    /// @custom:access Restricted to the Sickle owner.
    function setMinChargeInterval(
        Sickle sickle,
        uint256 permission,
        uint32 interval
    ) external {
        _validateSickle(sickle);
        _onlySickleOwner(sickle);

        minChargeInterval[sickle][permission] = interval;

        emit MinChargeIntervalSet(sickle, permission, interval);
    }

    /// @notice Authorize or revoke an automation contract as a gas charger.
    /// @custom:access Restricted to protocol admin.
    function setAuthorizedCharger(
        address charger,
        bool authorized
    ) external onlyAdmin {
        authorizedCharger[charger] = authorized;

        emit AuthorizedChargerSet(charger, authorized);
    }

    /// @notice Require or relax cadence settings for a chargeable permission.
    /// @custom:access Restricted to protocol admin.
    function setCadenceRequired(
        uint256 permission,
        bool required
    ) external onlyAdmin {
        cadenceRequired[permission] = required;

        emit CadenceRequiredSet(permission, required);
    }

    /// @notice Preflight a gas-account charge cadence. Automation calls this
    /// before strategy execution so a too-frequent charge fails before work is
    /// performed.
    function validateCadence(
        Sickle sickle,
        uint256 permission
    ) external view {
        _validateSickle(sickle);
        _validateCadence(sickle, permission);
    }

    /// @notice Debit a Sickle's prepaid gas balance and reimburse a recipient
    /// the actual metered transaction cost.
    /// @dev The charge must not exceed the Sickle's `maxChargeableFee` cap —
    /// an op above the cap (e.g. during a gas spike) reverts instead of
    /// draining the balance. A zero cap reverts every charge, so a Sickle is
    /// only chargeable once its owner has set a cap. `charge` is restricted to
    /// admin-authorized chargers (the v2 Automation), so an arbitrary caller
    /// cannot drain a balance; the keeper is expected to pre-filter Sickles
    /// whose cap or balance is below an op's cost off-chain.
    /// @custom:access Restricted to authorized chargers.
    function charge(
        Sickle sickle,
        uint256 amount,
        address recipient,
        uint256 permission
    ) external {
        _validateSickle(sickle);
        if (!authorizedCharger[msg.sender]) {
            revert NotAuthorizedCharger(msg.sender);
        }
        if (recipient == address(0)) revert InvalidRecipient();
        _validateCadence(sickle, permission);

        uint256 max = maxChargeableFee[sickle];
        if (amount > max) {
            revert ChargeExceedsMaxChargeableFee(amount, max);
        }

        uint256 balance = balances[sickle];
        if (amount > balance) {
            revert InsufficientGasAccountBalance(amount, balance);
        }

        balances[sickle] = balance - amount;
        _recordCadence(sickle, permission);
        SafeTransferLib.safeTransferETH(recipient, amount);

        emit TransactionCostCharged(recipient, amount);
    }

    function balanceOf(
        Sickle sickle
    ) external view returns (uint256) {
        return balances[sickle];
    }

    function _onlySickleOwner(
        Sickle sickle
    ) internal view {
        if (factory.admins(address(sickle)) != msg.sender) {
            revert NotSickleOwner();
        }
    }

    function _validateSickle(
        Sickle sickle
    ) internal view {
        if (
            address(sickle) == address(0)
                || factory.admins(address(sickle)) == address(0)
        ) {
            revert InvalidSickle();
        }
    }

    function _validateCadence(
        Sickle sickle,
        uint256 permission
    ) internal view {
        if (!cadenceRequired[permission]) {
            return;
        }

        uint32 interval = minChargeInterval[sickle][permission];
        if (interval == 0) {
            revert ChargeCadenceIntervalNotSet(sickle, permission);
        }

        uint64 last = lastChargedAt[sickle][permission];
        if (last == 0) {
            return;
        }

        uint256 nextRunAt = uint256(last) + interval;
        if (block.timestamp < nextRunAt) {
            revert ChargeCadenceNotElapsed(
                sickle, permission, nextRunAt, block.timestamp
            );
        }
    }

    function _recordCadence(
        Sickle sickle,
        uint256 permission
    ) internal {
        if (!cadenceRequired[permission]) {
            return;
        }

        uint64 timestamp = uint64(block.timestamp);
        lastChargedAt[sickle][permission] = timestamp;
        emit ChargeCadenceRecorded(sickle, permission, timestamp);
    }
}
