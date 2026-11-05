// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Admin } from "contracts/base/Admin.sol";
import { NonDelegateMulticall } from "contracts/base/NonDelegateMulticall.sol";
import { Sickle } from "contracts/Sickle.sol";
import { SickleRegistry } from "contracts/SickleRegistry.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { IAutomation } from "contracts/interfaces/IAutomation.sol";
import { INftAutomation } from "contracts/interfaces/INftAutomation.sol";
import {
    NftRebalance,
    NftPosition,
    NftIncrease,
    NftHarvest,
    NftWithdraw,
    NftCompound
} from "contracts/structs/NftFarmStrategyStructs.sol";
import {
    Farm,
    HarvestParams,
    WithdrawParams,
    CompoundParams
} from "contracts/structs/FarmStrategyStructs.sol";
import { AutomationPermissions } from
    "contracts/libraries/AutomationPermissions.sol";
import { GasAccount } from "contracts/GasAccount.sol";
import { IGasCostAdapter } from "contracts/interfaces/IGasCostAdapter.sol";
import {
    INftDepositCallback
} from "contracts/interfaces/INftDepositCallback.sol";
import {
    INftRebalanceCallback
} from "contracts/interfaces/INftRebalanceCallback.sol";

// @title Automation contract for protocol farming and NFT strategies
// @notice Allows protocol-approved automators, or user-approved automators via
// AutomatorPermissionsRegistry, to perform automated actions (compound,
// harvest,
// exit, rebalance) on behalf of Sickle users. For non-NFT positions, users can
// set automation preferences per position in PositionSettingsRegistry. For NFT
// positions, automation preferences are set per NFT in NftSettingsRegistry.
// AutomatorPermissionsRegistry enables Sickle owners to grant automation rights
// to specific addresses, overriding the global automator if desired.
// @dev Intended for use by off-chain automation bots with appropriate
// permissions. Protocol admin manages the global automator, while users can
// configure their own automator permissions and automation settings.
// @dev Beyond the fixed typed entrypoints (compound/harvest/exit/rebalance),
// `executeFor` is a generic permissioned dispatch: the admin binds a
// (strategy, selector) pair to a permission bit via `setActionPermission`,
// and automators then route any registered call through it. New automation
// categories plug in without redeploying this contract or migrating Sickles.
contract Automation is Admin, NonDelegateMulticall {
    error InvalidInputLength();
    error NotApprovedAutomator();
    error InvalidAutomator();
    error ApprovedAutomatorNotSet(address approvedAutomator);
    error ApprovedAutomatorAlreadySet(address approvedAutomator);
    error InvalidCallData();
    error ActionNotRegistered(address strategy, bytes4 selector);
    error ActionNotConsented(Sickle sickle, uint256 permission);
    error NotSickleOwner();
    error SickleMismatch();
    error EthValueMismatch();
    error InvalidVaultOwner();
    error InvalidCallback();

    error InvalidActionPermission(uint256 permission);
    error MulticallDisabled();

    event HarvestedFor(
        Sickle indexed sickle,
        address indexed stakingContract,
        uint256 indexed poolIndex,
        address automator
    );
    event CompoundedFor(
        Sickle indexed sickle,
        address indexed claimStakingContract,
        uint256 claimPoolIndex,
        address indexed depositStakingContract,
        uint256 depositPoolIndex,
        address automator
    );
    event ExitedFor(
        Sickle indexed sickle,
        address indexed stakingContract,
        uint256 indexed poolIndex,
        address automator
    );

    event NftHarvestedFor(
        Sickle indexed sickle,
        address indexed nftAddress,
        uint256 indexed tokenId,
        address automator
    );
    event NftCompoundedFor(
        Sickle indexed sickle,
        address indexed nftAddress,
        uint256 indexed tokenId,
        address automator
    );
    event NftExitedFor(
        Sickle indexed sickle,
        address indexed nftAddress,
        uint256 indexed tokenId,
        address automator
    );
    event NftRebalancedFor(
        Sickle indexed sickle,
        address indexed nftAddress,
        uint256 indexed tokenId,
        address automator
    );
    event AutomatedFor(
        Sickle indexed sickle,
        address indexed strategy,
        bytes4 indexed selector,
        address automator
    );
    event ActionPermissionSet(
        address indexed strategy, bytes4 indexed selector, uint256 permission
    );
    event ActionConsentSet(Sickle indexed sickle, uint256 consent);
    event GasAccountSet(GasAccount gasAccount);
    event GasCostAdapterSet(IGasCostAdapter gasCostAdapter);
    event NftDepositedFor(
        Sickle indexed sickle,
        address indexed nftAddress,
        uint256 indexed tokenId,
        address automator
    );
    event NftRebalanceCallbackSet(
        Sickle indexed sickle, address indexed callback
    );
    event NftDepositCallbackSet(
        Sickle indexed sickle, address indexed callback
    );

    event ApprovedAutomatorSet(address approvedAutomator);
    event ApprovedAutomatorPermissionsSet(
        address approvedAutomator, uint256 permissions
    );
    event ApprovedAutomatorRevoked(address approvedAutomator);
    event CustomAutomatorSet(
        Sickle indexed sickle, address indexed automator, uint256 permissions
    );

    address[] public approvedAutomators;
    mapping(address => bool) public isApprovedAutomator;
    mapping(address => uint256) public globalAutomatorPermissions;

    mapping(Sickle => mapping(address => uint256)) public
        customAutomatorPermissions;
    mapping(Sickle => uint256) public customAutomatorCount;
    mapping(Sickle => INftRebalanceCallback) public nftRebalanceCallback;
    mapping(Sickle => INftDepositCallback) public nftDepositCallback;

    /// @notice Permission bit required to invoke a (strategy, selector) pair
    /// through `executeFor`. Zero means the pair is not registered and the
    /// generic dispatch rejects it.
    mapping(address => mapping(bytes4 => uint256)) public actionPermission;

    /// @notice Per-Sickle bitmask (same bits as AutomationPermissions) of the
    /// automation categories the Sickle owner permits. Zero — the default —
    /// means no automation is consented: every entrypoint is fail-closed
    /// until the owner calls `setActionConsent`.
    mapping(Sickle => uint256) public actionConsent;

    /// @notice SickleFactory, used to resolve a Sickle's owner for the
    /// `setActionConsent` access check.
    SickleFactory public immutable factory;

    /// @notice Optional prepaid gas escrow. When set alongside
    /// `gasCostAdapter`, each `executeFor` op acting on a Sickle in
    /// gas-account mode (a non-zero GasAccount cap) reimburses the keeper
    /// from the Sickle's prepaid balance. The zero address disables
    /// gas-account charging — automation then runs purely on the reward fee.
    GasAccount public gasAccount;

    /// @notice Per-chain adapter converting an op's measured L2 gas into the
    /// native-token charge (adding the L1 data fee, operator fee and a
    /// calibrated overhead). Required for gas-account charging to run.
    IGasCostAdapter public gasCostAdapter;

    constructor(
        SickleRegistry registry,
        SickleFactory factory_,
        address admin
    ) Admin(admin) NonDelegateMulticall(registry) {
        factory = factory_;
    }

    function setCustomAutomatorForSickle(
        Sickle sickle,
        address automator,
        uint256 permissions
    ) external onlyAdmin {
        uint256 prevPermissions = customAutomatorPermissions[sickle][automator];

        if (prevPermissions == 0 && permissions != 0) {
            customAutomatorCount[sickle] += 1;
        } else if (prevPermissions != 0 && permissions == 0) {
            customAutomatorCount[sickle] -= 1;
        }

        customAutomatorPermissions[sickle][automator] = permissions;
        emit CustomAutomatorSet(sickle, automator, permissions);
    }

    function setNftRebalanceCallback(
        Sickle sickle,
        INftRebalanceCallback callback
    ) external {
        if (msg.sender != sickle.owner()) revert InvalidVaultOwner();
        _requireAllowedCallback(address(callback));
        nftRebalanceCallback[sickle] = callback;
        emit NftRebalanceCallbackSet(sickle, address(callback));
    }

    function setNftDepositCallback(
        Sickle sickle,
        INftDepositCallback callback
    ) external {
        if (msg.sender != sickle.owner()) revert InvalidVaultOwner();
        _requireAllowedCallback(address(callback));
        nftDepositCallback[sickle] = callback;
        emit NftDepositCallbackSet(sickle, address(callback));
    }

    /// @dev Constrain which address a Sickle owner may register as an
    /// automation callback, since Automation calls into it during
    /// depositFor/rebalanceFor. A callback must be either:
    ///  - `address(0)`: clears the callback; or
    ///  - `msg.sender`: the Sickle owner registering ITSELF. This is the
    ///    NftFarmVault pattern — the vault owns its Sickle and is its own
    ///    callback, so it is trusted by construction and self-registers in its
    ///    constructor (keeping vault deployment one-shot).
    /// This blocks an owner from pointing automation at any third-party
    /// contract. A self-callback grants no privilege — Automation `CALL`s (never
    /// `delegatecall`s) it, so `msg.sender == Automation` holds only inside the
    /// callback's own frame and never transfers to an onward call; it cannot
    /// escalate or reach another Sickle. The worst it can do is revert and
    /// grief automation on the owner's own Sickle, which keepers filter
    /// off-chain.
    function _requireAllowedCallback(
        address callback
    ) private view {
        if (callback != address(0) && callback != msg.sender) {
            revert InvalidCallback();
        }
    }

    /// Public functions

    function approvedAutomatorsLength() external view returns (uint256) {
        return approvedAutomators.length;
    }

    // Admin functions

    /// @notice Update approved automator address.
    /// @dev Controls which external address is allowed to
    /// compound farming positions for Sickles. This is expected to be the EOA
    /// of an automation bot.
    /// @custom:access Restricted to protocol admin.
    function setApprovedAutomator(
        address payable approvedAutomator
    ) external onlyAdmin {
        _setApprovedAutomator(approvedAutomator, AutomationPermissions.ALL);
    }

    /// @notice Update approved automator with permissions bitmap.
    /// If not already in the global allowlist, adds it.
    function setApprovedAutomatorWithPermissions(
        address payable approvedAutomator,
        uint256 permissions
    ) external onlyAdmin {
        if (!isApprovedAutomator[approvedAutomator]) {
            _setApprovedAutomator(approvedAutomator, permissions);
        } else {
            globalAutomatorPermissions[approvedAutomator] = permissions;
            emit ApprovedAutomatorPermissionsSet(approvedAutomator, permissions);
        }
    }

    function revokeApprovedAutomator(
        address approvedAutomator
    ) external onlyAdmin {
        if (!isApprovedAutomator[approvedAutomator]) {
            revert ApprovedAutomatorNotSet(approvedAutomator);
        }
        for (uint256 i; i < approvedAutomators.length; i++) {
            if (approvedAutomators[i] == approvedAutomator) {
                approvedAutomators[i] =
                    approvedAutomators[approvedAutomators.length - 1];
                approvedAutomators.pop();
                break;
            }
        }
        isApprovedAutomator[approvedAutomator] = false;
        delete globalAutomatorPermissions[approvedAutomator];
        emit ApprovedAutomatorPermissionsSet(approvedAutomator, 0);
        emit ApprovedAutomatorRevoked(approvedAutomator);
    }

    // Automator functions

    function compoundFor(
        IAutomation[] memory strategies,
        Sickle[] memory sickles,
        CompoundParams[] memory params,
        address[][] memory sweepTokens
    ) external {
        uint256 strategiesLength = strategies.length;
        if (
            strategiesLength != sickles.length
                || strategiesLength != params.length
                || strategiesLength != sweepTokens.length
        ) {
            revert InvalidInputLength();
        }

        _requireAuthorizedFor(sickles, AutomationPermissions.FARM_COMPOUND);

        address[] memory targets = new address[](strategiesLength);
        bytes[] memory data = new bytes[](strategiesLength);
        for (uint256 i; i < strategiesLength;) {
            Sickle sickle = sickles[i];
            CompoundParams memory param = params[i];
            targets[i] = address(strategies[i]);
            data[i] = abi.encodeCall(
                IAutomation.compoundFor, (sickle, param, sweepTokens[i])
            );
            emit CompoundedFor(
                sickle,
                param.claimFarm.stakingContract,
                param.claimFarm.poolIndex,
                param.depositFarm.stakingContract,
                param.depositFarm.poolIndex,
                msg.sender
            );
            unchecked {
                ++i;
            }
        }
        _multicall(targets, data);
    }

    function harvestFor(
        IAutomation[] memory strategies,
        Sickle[] memory sickles,
        Farm[] memory farms,
        HarvestParams[] memory params,
        address[][] memory sweepTokens
    ) external {
        uint256 strategiesLength = strategies.length;
        if (
            strategiesLength != sickles.length
                || strategiesLength != farms.length
                || strategiesLength != params.length
                || strategiesLength != sweepTokens.length
        ) {
            revert InvalidInputLength();
        }

        _requireAuthorizedFor(sickles, AutomationPermissions.FARM_HARVEST);

        address[] memory targets = new address[](strategiesLength);
        bytes[] memory data = new bytes[](strategiesLength);
        for (uint256 i; i < strategiesLength;) {
            Sickle sickle = sickles[i];
            Farm memory farm = farms[i];
            HarvestParams memory param = params[i];
            targets[i] = address(strategies[i]);
            data[i] = abi.encodeCall(
                IAutomation.harvestFor, (sickle, farm, param, sweepTokens[i])
            );
            emit HarvestedFor(
                sickle, farm.stakingContract, farm.poolIndex, msg.sender
            );
            unchecked {
                ++i;
            }
        }
        _multicall(targets, data);
    }

    function exitFor(
        IAutomation[] memory strategies,
        Sickle[] memory sickles,
        Farm[] memory farms,
        HarvestParams[] memory harvestParams,
        address[][] memory harvestSweepTokens,
        WithdrawParams[] memory withdrawParams,
        address[][] memory withdrawSweepTokens
    ) external {
        uint256 strategiesLength = strategies.length;
        if (
            strategiesLength != sickles.length
                || strategiesLength != farms.length
                || strategiesLength != harvestParams.length
                || strategiesLength != withdrawParams.length
                || strategiesLength != harvestSweepTokens.length
                || strategiesLength != withdrawSweepTokens.length
        ) {
            revert InvalidInputLength();
        }

        _requireAuthorizedFor(sickles, AutomationPermissions.FARM_EXIT);

        address[] memory targets = new address[](strategiesLength);
        bytes[] memory data = new bytes[](strategiesLength);
        for (uint256 i; i < strategiesLength;) {
            targets[i] = address(strategies[i]);
            data[i] = abi.encodeCall(
                IAutomation.exitFor,
                (
                    sickles[i],
                    farms[i],
                    harvestParams[i],
                    harvestSweepTokens[i],
                    withdrawParams[i],
                    withdrawSweepTokens[i]
                )
            );
            emit ExitedFor(
                sickles[i],
                farms[i].stakingContract,
                farms[i].poolIndex,
                msg.sender
            );
            unchecked {
                ++i;
            }
        }
        _multicall(targets, data);
    }

    // NFT Automator functions
    // Validation is done in the NftAutomation contract

    function depositFor(
        INftAutomation[] memory strategies,
        Sickle[] memory sickles,
        NftPosition[] memory positions,
        NftIncrease[] memory params,
        address[][] memory sweepTokens
    ) external {
        uint256 strategiesLength = strategies.length;
        if (
            strategiesLength != sickles.length
                || strategiesLength != positions.length
                || strategiesLength != params.length
                || strategiesLength != sweepTokens.length
        ) {
            revert InvalidInputLength();
        }

        _requireAuthorizedFor(sickles, AutomationPermissions.NFT_DUST_DEPOSIT);

        for (uint256 i; i < strategiesLength;) {
            Sickle sickle = sickles[i];
            NftPosition memory position = positions[i];
            NftIncrease memory param = params[i];
            INftAutomation strategy = strategies[i];
            if (!registry.isWhitelistedTarget(address(strategy))) {
                revert TargetNotWhitelisted(address(strategy));
            }

            INftDepositCallback callback = nftDepositCallback[sickle];
            if (address(callback) == address(0)) revert InvalidVaultOwner();
            callback.beforeDeposit(sickle, position, param);

            strategy.depositFor(sickle, position, param, sweepTokens[i]);
            emit NftDepositedFor(
                sickle, address(position.nft), position.tokenId, msg.sender
            );
            unchecked {
                ++i;
            }
        }
    }

    function harvestFor(
        INftAutomation[] memory strategies,
        Sickle[] memory sickles,
        NftPosition[] memory positions,
        NftHarvest[] memory params
    ) external {
        uint256 strategiesLength = strategies.length;
        if (
            strategiesLength != sickles.length
                || strategiesLength != positions.length
                || strategiesLength != params.length
        ) {
            revert InvalidInputLength();
        }

        _requireAuthorizedFor(sickles, AutomationPermissions.NFT_HARVEST);

        address[] memory targets = new address[](strategiesLength);
        bytes[] memory data = new bytes[](strategiesLength);
        for (uint256 i; i < strategiesLength;) {
            Sickle sickle = sickles[i];
            NftPosition memory position = positions[i];
            targets[i] = address(strategies[i]);
            data[i] = abi.encodeCall(
                INftAutomation.harvestFor, (sickle, position, params[i])
            );
            emit NftHarvestedFor(
                sickle, address(position.nft), position.tokenId, msg.sender
            );
            unchecked {
                ++i;
            }
        }
        _multicall(targets, data);
    }

    function compoundFor(
        INftAutomation[] memory strategies,
        Sickle[] memory sickles,
        NftPosition[] memory positions,
        NftCompound[] memory params,
        bool[] memory inPlace,
        address[][] memory sweepTokens
    ) external {
        uint256 strategiesLength = strategies.length;
        if (
            strategiesLength != sickles.length
                || strategiesLength != positions.length
                || strategiesLength != params.length
                || strategiesLength != inPlace.length
                || strategiesLength != sweepTokens.length
        ) {
            revert InvalidInputLength();
        }

        _requireAuthorizedFor(sickles, AutomationPermissions.NFT_COMPOUND);

        address[] memory targets = new address[](strategiesLength);
        bytes[] memory data = new bytes[](strategiesLength);
        for (uint256 i; i < strategiesLength;) {
            Sickle sickle = sickles[i];
            NftPosition memory position = positions[i];
            targets[i] = address(strategies[i]);
            data[i] = abi.encodeCall(
                INftAutomation.compoundFor,
                (sickle, position, params[i], inPlace[i], sweepTokens[i])
            );
            emit NftCompoundedFor(
                sickle, address(position.nft), position.tokenId, msg.sender
            );
            unchecked {
                ++i;
            }
        }
        _multicall(targets, data);
    }

    function exitFor(
        INftAutomation[] memory strategies,
        Sickle[] memory sickles,
        NftPosition[] memory positions,
        NftHarvest[] memory harvestParams,
        NftWithdraw[] memory withdrawParams,
        address[][] memory sweepTokens
    ) external {
        uint256 strategiesLength = strategies.length;
        if (
            strategiesLength != sickles.length
                || strategiesLength != positions.length
                || strategiesLength != harvestParams.length
                || strategiesLength != withdrawParams.length
                || strategiesLength != sweepTokens.length
        ) {
            revert InvalidInputLength();
        }

        _requireAuthorizedFor(sickles, AutomationPermissions.NFT_EXIT);

        address[] memory targets = new address[](strategiesLength);
        bytes[] memory data = new bytes[](strategiesLength);
        for (uint256 i; i < strategiesLength;) {
            Sickle sickle = sickles[i];
            NftPosition memory position = positions[i];
            targets[i] = address(strategies[i]);
            data[i] = abi.encodeCall(
                INftAutomation.exitFor,
                (
                    sickle,
                    position,
                    harvestParams[i],
                    withdrawParams[i],
                    sweepTokens[i]
                )
            );
            emit NftExitedFor(
                sickle, address(position.nft), position.tokenId, msg.sender
            );
            unchecked {
                ++i;
            }
        }
        _multicall(targets, data);
    }

    function rebalanceFor(
        INftAutomation[] memory strategies,
        Sickle[] memory sickles,
        NftRebalance[] memory params,
        address[][] memory sweepTokens
    ) external {
        uint256 strategiesLength = strategies.length;
        if (
            strategiesLength != sickles.length
                || strategiesLength != params.length
                || strategiesLength != sweepTokens.length
        ) {
            revert InvalidInputLength();
        }

        _requireAuthorizedFor(sickles, AutomationPermissions.NFT_REBALANCE);

        // Callbacks are owner-supplied code, so each Sickle's must bracket only
        // its own rebalance -- never another owner's. Hence the per-item
        // ordering here rather than global phases, matching `depositFor`.
        // `_multicall` is only a whitelist-checked call sequence, so the check
        // is inlined and the calls made directly.
        for (uint256 i; i < strategiesLength;) {
            NftRebalance memory param = params[i];
            Sickle sickle = sickles[i];
            INftAutomation strategy = strategies[i];

            if (!registry.isWhitelistedTarget(address(strategy))) {
                revert TargetNotWhitelisted(address(strategy));
            }

            // Snapshot the pre-rebalance position value while it is still
            // intact (the rebalance below drains it).
            INftRebalanceCallback callback = nftRebalanceCallback[sickle];
            if (address(callback) != address(0)) {
                callback.beforeRebalance(sickle, param.position);
            }

            strategy.rebalanceFor(sickle, param, sweepTokens[i]);

            emit NftRebalancedFor(
                sickle,
                address(param.position.nft),
                param.position.tokenId,
                msg.sender
            );

            if (address(callback) != address(0)) {
                callback.onRebalance(sickle, param.position);
            }
            unchecked {
                ++i;
            }
        }
    }

    // Generic automator dispatch

    /// @notice Disabled. `Automation` batches only its own work, through the
    /// internal `_multicall`, so nothing should reach the inherited external
    /// entrypoint.
    /// @dev Left in place rather than removed because an inherited external
    /// function cannot be deleted. Closing it drops a permissioned surface
    /// that every registry-whitelisted caller could otherwise reach, and
    /// removes automation's dependence on `Automation` itself remaining a
    /// whitelisted caller — a registry change can no longer break batching.
    function multicall(
        address[] calldata,
        bytes[] calldata
    ) external payable override {
        revert MulticallDisabled();
    }

    /// @notice Register (or update) the permission bit required to invoke
    /// `selector` on `strategy` through `executeFor`. Passing a zero
    /// permission unregisters the pair, after which `executeFor` rejects it.
    /// @dev This map doubles as a strict allowlist: `executeFor` can only
    /// reach (strategy, selector) pairs an admin has explicitly registered.
    /// @custom:access Restricted to protocol admin.
    function setActionPermission(
        address strategy,
        bytes4 selector,
        uint256 permission
    ) external onlyAdmin {
        // Zero unregisters. Every other value must be a single bit:
        // authorization treats the mask as a SET of required bits
        // (`consent & action != action`), while GasAccount looks the same
        // value up as ONE exact cadence key. A composite such as
        // MULTI_COMPOUND|FARM_HARVEST would therefore demand both bits to
        // authorize, yet inherit neither bit's configured cadence, because
        // cadenceRequired[A|B] is a different slot from cadenceRequired[A]
        // and cadenceRequired[B].
        // The `!= 0` is load-bearing, not just a short-circuit: checked
        // arithmetic makes `permission - 1` panic at zero.
        if (permission != 0 && permission & (permission - 1) != 0) {
            revert InvalidActionPermission(permission);
        }
        actionPermission[strategy][selector] = permission;
        emit ActionPermissionSet(strategy, selector, permission);
    }

    /// @notice Set which automation categories an automator may perform on
    /// `sickle`. The mask uses the AutomationPermissions bits and is checked
    /// — in addition to the automator's own permissions — by every `*For`
    /// entrypoint, so a Sickle is not automatable until its owner opts in.
    /// Overwrites the previous mask.
    /// @custom:access Restricted to the Sickle's owner.
    function setActionConsent(
        Sickle sickle,
        uint256 consent
    ) external {
        if (factory.admins(address(sickle)) != msg.sender) {
            revert NotSickleOwner();
        }
        actionConsent[sickle] = consent;
        emit ActionConsentSet(sickle, consent);
    }

    /// @notice Wire (or unset, with the zero address) the prepaid GasAccount
    /// escrow used to reimburse keepers for ops on gas-account-mode Sickles.
    /// @dev `GasAccount` is deploy-once and must separately authorize this
    /// contract as a charger; until both sides are wired, `executeFor`
    /// charges nothing.
    /// @custom:access Restricted to protocol admin.
    function setGasAccount(
        GasAccount gasAccount_
    ) external onlyAdmin {
        gasAccount = gasAccount_;
        emit GasAccountSet(gasAccount_);
    }

    /// @notice Wire (or unset, with the zero address) the per-chain gas-cost
    /// adapter used to price metered ops.
    /// @custom:access Restricted to protocol admin.
    function setGasCostAdapter(
        IGasCostAdapter gasCostAdapter_
    ) external onlyAdmin {
        gasCostAdapter = gasCostAdapter_;
        emit GasCostAdapterSet(gasCostAdapter_);
    }

    /// @notice Generic permissioned automation dispatch.
    /// @dev Routes each call to a strategy whose (strategy, selector) pair the
    /// admin registered via `setActionPermission`. New automation categories
    /// (multi-compound, vaults, lending, ...) plug in by registering their
    /// selectors — no Automation redeploy and no per-Sickle migration. Safety
    /// is enforced downstream: every automation entrypoint is `onlyApproved`
    /// (msg.sender == sickle.approved() == this) and validates the position's
    /// opt-in against its settings registry. An unregistered pair reverts.
    /// @param strategies Strategy contract to call for each item.
    /// @param sickles Sickle each call acts on; gates the permission check.
    /// Must equal the Sickle encoded as the first argument of the matching
    /// `callData` — every automation `*For` entrypoint takes its Sickle
    /// first, and this binding stops a caller authorized for one Sickle from
    /// invoking the action on another.
    /// @param callData ABI-encoded strategy call, selector-first.
    /// @param values ETH forwarded per call (e.g. GMX execution fees); must
    /// sum to `msg.value`.
    function executeFor(
        address[] calldata strategies,
        Sickle[] calldata sickles,
        bytes[] calldata callData,
        uint256[] calldata values
    ) external payable {
        uint256 len = strategies.length;
        if (
            len != sickles.length || len != callData.length
                || len != values.length
        ) {
            revert InvalidInputLength();
        }

        uint256 totalValue;
        for (uint256 i; i < len;) {
            totalValue += values[i];
            // Per-item work is delegated to keep this frame shallow — four
            // calldata-array params already crowd the stack.
            _executeOne(
                strategies[i], sickles[i], callData[i], values[i], len
            );
            unchecked {
                ++i;
            }
        }

        if (totalValue != msg.value) revert EthValueMismatch();
    }

    /// @dev Validates, authorizes and dispatches a single executeFor item.
    function _executeOne(
        address strategy,
        Sickle sickle,
        bytes calldata data,
        uint256 value,
        uint256 batchSize
    ) private {
        // selector (4 bytes) + the Sickle every automation *For entrypoint
        // takes as its first ABI argument (32 bytes).
        if (data.length < 36) revert InvalidCallData();
        bytes4 selector = bytes4(data[:4]);

        uint256 permission = actionPermission[strategy][selector];
        if (permission == 0) {
            revert ActionNotRegistered(strategy, selector);
        }

        // Bind the authorized Sickle to the call: the strategy acts on
        // whatever Sickle the calldata encodes, so a caller authorized for
        // `sickle` must not be able to target a different one.
        if (
            address(uint160(uint256(bytes32(data[4:36]))))
                != address(sickle)
        ) {
            revert SickleMismatch();
        }
        _requireAuthorized(sickle, permission);
        bool charged = _preflightGasAccountCadence(sickle, permission);

        // Meter the op so a gas-account Sickle can reimburse the keeper. The
        // window covers only the strategy call; the intrinsic gas, calldata
        // and the charging tail are outside the measured strategy window.
        // Adapter overhead is intentionally per-op marginal only; tx-wide
        // fixed costs must not be charged once per item in a batch.
        uint256 gasBefore = gasleft();
        (bool success, bytes memory result) =
            strategy.call{ value: value }(data);
        uint256 gasUsed = gasBefore - gasleft();
        if (!success) {
            if (result.length == 0) revert();
            assembly {
                revert(add(32, result), mload(result))
            }
        }

        _chargeGasAccount(
            sickle, permission, gasUsed, data, charged, batchSize
        );

        emit AutomatedFor(sickle, strategy, selector, msg.sender);
    }

    /// @dev Fail cadence-gated gas-account ops before doing strategy work.
    /// Fee-mode Sickles (zero maxChargeableFee) skip this check, matching the
    /// charge path.
    /// @dev Decide, BEFORE the strategy runs, whether this op is charged from
    /// the Sickle's prepaid balance, and return that decision so settlement
    /// cannot re-derive it afterwards. Strategies commonly finish by sweeping
    /// to the Sickle owner, and a native-token transfer hands a
    /// contract-based owner control mid-operation; from there it can call
    /// `GasAccount.setMaxChargeableFee(sickle, 0)`, which the owner is
    /// entitled to do. Re-reading the cap at settlement would then observe
    /// fee mode and skip payment, leaving the keeper to fund a completed
    /// operation and leaving `lastChargedAt` unset so the cadence limit never
    /// advances. A reentrancy guard here would not help — the callback
    /// mutates GasAccount directly.
    function _preflightGasAccountCadence(
        Sickle sickle,
        uint256 permission
    ) private view returns (bool charged) {
        GasAccount account = gasAccount;
        IGasCostAdapter adapter = gasCostAdapter;
        if (
            address(account) == address(0) || address(adapter) == address(0)
        ) {
            return false;
        }
        if (account.maxChargeableFee(sickle) == 0) {
            return false;
        }
        account.validateCadence(sickle, permission);
        return true;
    }

    /// @dev Reimburse the keeper for one op from the Sickle's prepaid gas
    /// balance. A no-op unless the protocol has wired both a `GasAccount` and
    /// a `GasCostAdapter` and the Sickle owner has set a `maxChargeableFee`
    /// cap — an unset (zero) cap is fee mode, where the keeper is paid by the
    /// reward fee and charging is skipped, so fee-mode automation is
    /// unaffected. The keeper is reimbursed its actual metered cost, but
    /// `GasAccount.charge` reverts when that cost exceeds the owner's per-op
    /// cap or the prepaid balance — reverting the whole `executeFor` batch, so
    /// the keeper is expected to pre-filter Sickles whose cap or balance is
    /// below an op's cost off-chain.
    /// @param data The per-op calldata — never the batched `msg.data` — so a
    /// data-fee adapter prices this op alone, not the whole transaction.
    function _chargeGasAccount(
        Sickle sickle,
        uint256 permission,
        uint256 gasUsed,
        bytes calldata data,
        bool charged,
        uint256 batchSize
    ) private {
        // `charged` is the mode committed before the strategy ran; the cap is
        // deliberately NOT re-read here. If the owner zeroed it mid-operation,
        // `GasAccount.charge` now reverts on the cap check instead of this
        // returning early, so the operation and its payment succeed or fail
        // together rather than the operation persisting unpaid.
        if (!charged) {
            return; // fee mode — the Sickle owner has not set a per-op cap
        }
        // The adapter needs the batch size to share out components the chain
        // levies once per transaction; without it a batch of N charged N
        // Sickles the whole of a cost the keeper paid once.
        uint256 cost = gasCostAdapter.txCost(gasUsed, data, batchSize);
        gasAccount.charge(sickle, cost, msg.sender, permission);
    }

    // Internal

    function _setApprovedAutomator(
        address payable approvedAutomator,
        uint256 permissions
    ) internal {
        if (approvedAutomator == address(0)) revert InvalidAutomator();
        if (isApprovedAutomator[approvedAutomator]) {
            revert ApprovedAutomatorAlreadySet(approvedAutomator);
        }
        isApprovedAutomator[approvedAutomator] = true;
        approvedAutomators.push(approvedAutomator);
        globalAutomatorPermissions[approvedAutomator] = permissions;
        emit ApprovedAutomatorSet(approvedAutomator);
        emit ApprovedAutomatorPermissionsSet(approvedAutomator, permissions);
    }

    function _requireAuthorizedFor(
        Sickle[] memory sickles,
        uint256 action
    ) internal view {
        uint256 len = sickles.length;
        for (uint256 i; i < len;) {
            _requireAuthorized(sickles[i], action);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Reverts unless (a) the Sickle owner has consented to `action`
    /// via `setActionConsent`, and (b) msg.sender holds every bit of
    /// `action` for `sickle`. A Sickle with custom automators is gated
    /// solely by its custom permissions; otherwise the global automator
    /// allowlist applies. Consent is owner-controlled; the permissions are
    /// admin/automator-controlled — both are required.
    function _requireAuthorized(
        Sickle sickle,
        uint256 action
    ) internal view {
        if (actionConsent[sickle] & action != action) {
            revert ActionNotConsented(sickle, action);
        }
        if (customAutomatorCount[sickle] > 0) {
            if (
                (customAutomatorPermissions[sickle][msg.sender] & action)
                    != action
            ) {
                revert NotApprovedAutomator();
            }
        } else {
            if (
                !isApprovedAutomator[msg.sender]
                    || (globalAutomatorPermissions[msg.sender] & action)
                        != action
            ) {
                revert NotApprovedAutomator();
            }
        }
    }
}
