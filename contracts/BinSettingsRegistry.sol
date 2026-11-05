// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SickleFactory } from "contracts/SickleFactory.sol";
import { Admin } from "contracts/base/Admin.sol";
import { BinKey, BinSettings } from "contracts/structs/BinSettingsStructs.sol";
import { BinAddLiquidity } from "contracts/structs/BinFarmStrategyStructs.sol";
import { RewardBehavior } from "contracts/structs/PositionSettingsStructs.sol";
import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";

/// @notice Per-pair consent for automated Liquidity Book positions.
/// @dev An owner opts in to a bin range, rather than an NFT token ID. A keeper
/// may only withdraw shares from that range; rebalance updates it atomically.
contract BinSettingsRegistry is Admin {
    error SickleNotDeployed();
    error InvalidPair();
    error InvalidRange();
    error InvalidRewardConfig();
    error InvalidTrigger();
    error AutoDepositNotSet();
    error AutoHarvestNotSet();
    error AutoCompoundNotSet();
    error AutoExitNotSet();
    error AutoRebalanceNotSet();
    error ActiveIdWithinRange();
    error ActiveIdOutsideCutoff();
    error ActiveIdOutsideBounds();
    error BinOutsideRange(uint256 id);
    error IdSlippageTooHigh();
    error RebalanceShapeMismatch();
    error ShiftRequiresRebalance();
    error ShiftTargetMismatch(uint24 expectedLow, uint24 expectedHigh);
    error ShiftMintMismatch(uint24 expectedLow, uint24 expectedHigh);
    error ShiftTargetUnchanged();
    error ShiftTargetTwoCycle();
    error ShiftTargetOutsideCutoff();
    error IncompleteWithdrawal(uint256 id);
    error OnlyStrategy();

    event BinSettingsSet(BinKey key, BinSettings settings);
    event BinRangeUpdated(BinKey key, uint24 rangeLow, uint24 rangeHigh);
    event BinSettingsCleared(BinKey key);
    event StrategySet(address strategy);
    event BridgeStrategySet(address strategy);

    SickleFactory public immutable factory;
    address public strategy;
    address public bridgeStrategy;
    mapping(bytes32 => BinSettings) private settingsMap;

    constructor(
        SickleFactory factory_,
        address admin_
    ) Admin(admin_) {
        factory = factory_;
    }

    function setStrategy(
        address strategy_
    ) external onlyAdmin {
        if (strategy_.code.length == 0) revert OnlyStrategy();
        strategy = strategy_;
        emit StrategySet(strategy_);
    }

    function setBridgeStrategy(
        address strategy_
    ) external onlyAdmin {
        if (strategy_.code.length == 0) revert OnlyStrategy();
        bridgeStrategy = strategy_;
        emit BridgeStrategySet(strategy_);
    }

    function getBinSettings(
        BinKey memory key
    ) public view returns (BinSettings memory) {
        return settingsMap[keccak256(abi.encode(key))];
    }

    /// @notice Whether burning this share balance returns at least one token.
    /// LBPair rounds each token output down and rejects a zero/zero burn.
    function isBurnable(
        ILBPair pair,
        uint256 id,
        uint256 balance
    ) public view returns (bool) {
        if (balance == 0) return false;
        if (id > type(uint24).max) revert InvalidRange();
        uint256 supply = pair.totalSupply(id);
        if (supply == 0) return false;
        (uint128 reserveX, uint128 reserveY) = pair.getBin(uint24(id));
        return (reserveX != 0 && balance > (supply - 1) / reserveX)
            || (reserveY != 0 && balance > (supply - 1) / reserveY);
    }

    /// @notice Read current balances and omit shares that cannot be burned.
    function burnableBalances(
        address sickle,
        ILBPair pair,
        uint256[] calldata requestedIds
    ) external view returns (uint256[] memory ids, uint256[] memory amounts) {
        uint256[] memory keptIds = new uint256[](requestedIds.length);
        uint256[] memory keptAmounts = new uint256[](requestedIds.length);
        uint256 count;
        for (uint256 i; i < requestedIds.length; ++i) {
            uint256 id = requestedIds[i];
            if (i != 0 && id <= requestedIds[i - 1]) revert InvalidRange();
            uint256 balance = pair.balanceOf(sickle, id);
            if (!isBurnable(pair, id, balance)) continue;
            keptIds[count] = id;
            keptAmounts[count] = balance;
            ++count;
        }
        if (count == 0) revert InvalidRange();
        ids = new uint256[](count);
        amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = keptIds[i];
            amounts[i] = keptAmounts[i];
        }
    }

    /// @notice The Sickle owner opts the entire configured bin range into
    /// keeper operations. Setting all flags false disables automation.
    function setBinSettings(
        BinKey calldata key,
        BinSettings calldata settings
    ) external {
        if (factory.admins(address(key.sickle)) != msg.sender) {
            revert SickleNotDeployed();
        }
        _setBinSettings(key, settings);
    }

    /// @notice Install owner-supplied automation settings for the bins actually
    /// minted by an owner deposit or move. The strategy authenticates the
    /// owner.
    function setAfterMint(
        BinKey calldata key,
        BinSettings calldata settings,
        uint256[] calldata mintedIds,
        uint256[] calldata mintedAmounts
    ) external {
        _requireOwnerStrategy();
        (uint24 low, uint24 high) = _mintedRange(mintedIds, mintedAmounts);
        BinSettings memory previous = getBinSettings(key);
        BinSettings memory actual = settings;
        // A second deposit into the same pair/farm adds to the existing
        // position. Keep every bin with shares inside the consent range.
        actual.rangeLow = previous.rangeHigh == 0 || low < previous.rangeLow
            ? low
            : previous.rangeLow;
        actual.rangeHigh = high > previous.rangeHigh ? high : previous.rangeHigh;
        if (
            previous.rangeHigh != 0 && actual.autoRebalance
                && (actual.rangeLow < actual.cutoffLow
                    || actual.rangeHigh > actual.cutoffHigh
                    || (actual.shiftConfig.enabled
                        && uint256(actual.rangeHigh) - actual.rangeLow
                            != uint256(previous.rangeHigh) - previous.rangeLow))
        ) {
            actual.autoRebalance = false;
            actual.shiftConfig.enabled = false;
        }
        _setBinSettings(key, actual);
    }

    function _setBinSettings(
        BinKey memory key,
        BinSettings memory settings
    ) private {
        if (address(key.lbPair) == address(0)) revert InvalidPair();
        if (settings.rangeLow > settings.rangeHigh) revert InvalidRange();
        if (
            !settings.automateRewards
                && settings.rewardConfig.rewardBehavior != RewardBehavior.None
        ) revert InvalidRewardConfig();
        if (
            settings.automateRewards
                && (key.stakingContract == address(0)
                    || settings.rewardConfig.rewardBehavior
                        == RewardBehavior.None)
        ) revert InvalidRewardConfig();
        if (
            settings.rewardConfig.rewardBehavior != RewardBehavior.Harvest
                && settings.rewardConfig.harvestTokenOut != address(0)
        ) revert InvalidRewardConfig();
        if (
            settings.autoRebalance
                && (settings.cutoffLow > settings.cutoffHigh
                    || settings.rangeLow < settings.cutoffLow
                    || settings.rangeHigh > settings.cutoffHigh
                    || int256(uint256(settings.rangeLow))
                            - settings.rebalanceBufferBelow
                        > int256(uint256(settings.rangeHigh))
                            + settings.rebalanceBufferAbove)
        ) revert InvalidTrigger();
        if (settings.autoRebalance && settings.rebalanceShapeHash == bytes32(0))
        {
            revert RebalanceShapeMismatch();
        }
        if (settings.shiftConfig.enabled && !settings.autoRebalance) {
            revert ShiftRequiresRebalance();
        }
        settingsMap[keccak256(abi.encode(key))] = settings;
        emit BinSettingsSet(key, settings);
    }

    function validateDepositFor(
        BinKey calldata key
    ) external view {
        if (!getBinSettings(key).autoDeposit) revert AutoDepositNotSet();
    }

    function validateMinted(
        BinKey calldata key,
        uint256[] calldata ids
    ) external view {
        _validateIds(getBinSettings(key), ids);
    }

    function validateHarvestFor(
        BinKey calldata key
    ) external view {
        BinSettings memory settings = getBinSettings(key);
        if (
            !settings.automateRewards
                || settings.rewardConfig.rewardBehavior
                    != RewardBehavior.Harvest
        ) revert AutoHarvestNotSet();
    }

    function validateCompoundFor(
        BinKey calldata key
    ) external view {
        BinSettings memory settings = getBinSettings(key);
        if (
            !settings.automateRewards
                || settings.rewardConfig.rewardBehavior
                    != RewardBehavior.Compound
        ) revert AutoCompoundNotSet();
    }

    function validateExitFor(
        BinKey calldata key,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external view {
        BinSettings memory settings = getBinSettings(key);
        if (!settings.autoExit) revert AutoExitNotSet();
        _validateIds(settings, ids);
        _validateFullWithdrawal(key, settings, ids, amounts);
        uint256 activeId = key.lbPair.getActiveId();
        if (
            activeId >= _lower(settings.rangeLow, settings.exitBufferBelow)
                && activeId
                    <= uint256(settings.rangeHigh) + settings.exitBufferAbove
        ) revert ActiveIdWithinRange();
    }

    function validateRebalanceFor(
        BinKey calldata key,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        BinAddLiquidity calldata addLp,
        uint24 minActiveId,
        uint24 maxActiveId
    ) external view returns (uint64 shiftTarget) {
        BinSettings memory settings = getBinSettings(key);
        if (!settings.autoRebalance) revert AutoRebalanceNotSet();
        _validateIds(settings, ids);
        if (addLp.idSlippage > settings.maxIdSlippage) {
            revert IdSlippageTooHigh();
        }
        if (
            keccak256(
                    abi.encode(
                        addLp.deltaIds, addLp.distributionX, addLp.distributionY
                    )
                ) != settings.rebalanceShapeHash
        ) {
            revert RebalanceShapeMismatch();
        }
        uint256 activeId = key.lbPair.getActiveId();
        bool below = _validateRebalanceTrigger(
            settings, activeId, minActiveId, maxActiveId
        );
        _validateFullWithdrawal(key, settings, ids, amounts);
        if (!settings.shiftConfig.enabled) return 0;
        return _validateShiftTarget(settings, addLp, activeId, below);
    }

    function _validateRebalanceTrigger(
        BinSettings memory settings,
        uint256 activeId,
        uint24 minActiveId,
        uint24 maxActiveId
    ) private pure returns (bool below) {
        if (
            (minActiveId != 0 || maxActiveId != 0)
                && (activeId < minActiveId || activeId > maxActiveId)
        ) revert ActiveIdOutsideBounds();
        int256 lowerTrigger =
            int256(uint256(settings.rangeLow)) - settings.rebalanceBufferBelow;
        int256 upperTrigger =
            int256(uint256(settings.rangeHigh)) + settings.rebalanceBufferAbove;
        below = int256(activeId) < lowerTrigger;
        bool above = int256(activeId) > upperTrigger;
        if (!below && !above) revert ActiveIdWithinRange();
        if (activeId < settings.cutoffLow || activeId > settings.cutoffHigh) {
            revert ActiveIdOutsideCutoff();
        }
    }

    function _validateShiftTarget(
        BinSettings memory settings,
        BinAddLiquidity calldata addLp,
        uint256 activeId,
        bool below
    ) private pure returns (uint64) {
        uint256 width = uint256(settings.rangeHigh) - settings.rangeLow;
        uint256 low;
        uint256 high;
        if (below) {
            high = activeId + settings.shiftConfig.entryBinsDown;
            if (high < width) revert InvalidRange();
            low = high - width;
        } else {
            if (activeId < settings.shiftConfig.entryBinsUp) {
                revert InvalidRange();
            }
            low = activeId - settings.shiftConfig.entryBinsUp;
            high = low + width;
        }
        if (high > type(uint24).max) revert InvalidRange();
        if (low == settings.rangeLow) revert ShiftTargetUnchanged();
        _validateNoTwoCycle(settings, activeId, low);
        if (low < settings.cutoffLow || high > settings.cutoffHigh) {
            revert ShiftTargetOutsideCutoff();
        }
        if (
            addLp.deltaIds.length == 0
                || int256(addLp.activeIdDesired) + addLp.deltaIds[0]
                    != int256(low)
                || int256(addLp.activeIdDesired)
                        + addLp.deltaIds[addLp.deltaIds.length - 1]
                    != int256(high)
        ) revert ShiftTargetMismatch(uint24(low), uint24(high));
        return (uint64(1) << 48) | (uint64(low) << 24) | uint64(high);
    }

    function _validateNoTwoCycle(
        BinSettings memory settings,
        uint256 activeId,
        uint256 targetLow
    ) private pure {
        uint256 width = uint256(settings.rangeHigh) - settings.rangeLow;
        if (activeId < settings.shiftConfig.entryBinsUp) return;
        uint256 upLow = activeId - settings.shiftConfig.entryBinsUp;
        uint256 downHigh = activeId + settings.shiftConfig.entryBinsDown;
        if (downHigh < width) return;
        uint256 downLow = downHigh - width;
        if (
            upLow != downLow
                && ((settings.rangeLow == upLow && targetLow == downLow)
                    || (settings.rangeLow == downLow && targetLow == upLow))
        ) revert ShiftTargetTwoCycle();
    }

    /// @notice Owner moves and rebalances may include bins outside the keeper
    /// consent range. Every supplied bin must be withdrawn in full, and every
    /// held bin inside the recorded range must be supplied.
    function validateOwnerFullWithdrawal(
        BinKey calldata key,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external view {
        BinSettings memory settings = getBinSettings(key);
        if (ids.length == 0 || ids.length != amounts.length) {
            revert InvalidRange();
        }
        for (uint256 i; i < ids.length; ++i) {
            if (i != 0 && ids[i] <= ids[i - 1]) revert InvalidRange();
            if (amounts[i] != key.lbPair.balanceOf(address(key.sickle), ids[i]))
            {
                revert IncompleteWithdrawal(ids[i]);
            }
        }
        uint256 next;
        for (uint256 id = settings.rangeLow; id <= settings.rangeHigh; ++id) {
            while (next < ids.length && ids[next] < id) ++next;
            uint256 balance = key.lbPair.balanceOf(address(key.sickle), id);
            if (
                (next == ids.length || ids[next] != id)
                    && isBurnable(key.lbPair, id, balance)
            ) revert IncompleteWithdrawal(id);
        }
    }

    function _validateFullWithdrawal(
        BinKey calldata key,
        BinSettings memory settings,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) private view {
        if (ids.length != amounts.length) revert InvalidRange();
        uint256 next;
        for (uint256 id = settings.rangeLow; id <= settings.rangeHigh; ++id) {
            uint256 balance = key.lbPair.balanceOf(address(key.sickle), id);
            if (next < ids.length && ids[next] == id) {
                if (amounts[next] != balance) {
                    revert IncompleteWithdrawal(id);
                }
                ++next;
            } else if (isBurnable(key.lbPair, id, balance)) {
                revert IncompleteWithdrawal(id);
            }
        }
        if (next != ids.length) revert IncompleteWithdrawal(ids[next]);
    }

    /// @dev Run after a successful keeper mint, before returning to Automation.
    /// The strategy address is the only writer of keeper-derived ranges.
    function updateRangeAfterRebalance(
        BinKey calldata key,
        uint256[] calldata mintedIds,
        uint256[] calldata mintedAmounts,
        uint64 shiftTarget
    ) external {
        if (msg.sender != strategy) revert OnlyStrategy();
        (uint24 low, uint24 high) = _mintedRange(mintedIds, mintedAmounts);
        if (
            shiftTarget != 0
                && (low != uint24(shiftTarget >> 24)
                    || high != uint24(shiftTarget))
        ) {
            revert ShiftMintMismatch(
                uint24(shiftTarget >> 24), uint24(shiftTarget)
            );
        }
        bytes32 hash = keccak256(abi.encode(key));
        settingsMap[hash].rangeLow = low;
        settingsMap[hash].rangeHigh = high;
        emit BinRangeUpdated(key, low, high);
    }

    /// @notice Owner rebalances choose a new relative shape. Keep future
    /// keeper actions bound to the position the owner actually minted.
    function updateAfterOwnerRebalance(
        BinKey calldata key,
        uint256[] calldata mintedIds,
        uint256[] calldata mintedAmounts,
        BinAddLiquidity calldata addLp
    ) external {
        if (msg.sender != strategy) revert OnlyStrategy();
        (uint24 low, uint24 high) = _mintedRange(mintedIds, mintedAmounts);
        bytes32 hash = keccak256(abi.encode(key));
        BinSettings storage settings = settingsMap[hash];
        settings.rangeLow = low;
        settings.rangeHigh = high;
        if (settings.autoRebalance) {
            settings.rebalanceShapeHash = keccak256(
                abi.encode(
                    addLp.deltaIds, addLp.distributionX, addLp.distributionY
                )
            );
        }
        emit BinRangeUpdated(key, low, high);
    }

    /// @notice Owner minting more shares keeps the consent range aligned with
    /// the complete position. Keeper mints are separately limited to the
    /// existing range and do not extend owner consent.
    function includeAfterOwnerMint(
        BinKey calldata key,
        uint256[] calldata mintedIds,
        uint256[] calldata mintedAmounts
    ) external {
        _requireOwnerStrategy();
        (uint24 low, uint24 high) = _mintedRange(mintedIds, mintedAmounts);
        BinSettings storage settings = settingsMap[keccak256(abi.encode(key))];
        if (settings.rangeHigh == 0) {
            // A full owner withdrawal clears automation consent. A later
            // owner increase starts a new, unautomated position that can
            // still be moved or rebalanced without manual registry repair.
            settings.rangeLow = low;
            settings.rangeHigh = high;
            emit BinRangeUpdated(key, low, high);
            return;
        }
        uint256 oldWidth = uint256(settings.rangeHigh) - settings.rangeLow;
        if (low < settings.rangeLow) settings.rangeLow = low;
        if (high > settings.rangeHigh) settings.rangeHigh = high;
        if (
            settings.autoRebalance
                && (settings.rangeLow < settings.cutoffLow
                    || settings.rangeHigh > settings.cutoffHigh
                    || (settings.shiftConfig.enabled
                        && uint256(settings.rangeHigh) - settings.rangeLow
                            != oldWidth))
        ) {
            settings.autoRebalance = false;
            settings.shiftConfig.enabled = false;
            emit BinSettingsSet(key, settings);
        }
        emit BinRangeUpdated(key, settings.rangeLow, settings.rangeHigh);
    }

    function _mintedRange(
        uint256[] calldata mintedIds,
        uint256[] calldata mintedAmounts
    ) private pure returns (uint24 low, uint24 high) {
        if (mintedIds.length == 0 || mintedIds.length != mintedAmounts.length) {
            revert InvalidRange();
        }
        uint256 lowId = type(uint24).max;
        uint256 highId;
        for (uint256 i; i < mintedIds.length; ++i) {
            if (mintedAmounts[i] == 0) continue;
            uint256 id = mintedIds[i];
            if (id > type(uint24).max) revert InvalidRange();
            if (id < lowId) lowId = id;
            if (id > highId) highId = id;
        }
        if (lowId == type(uint24).max && highId == 0) revert InvalidRange();
        return (uint24(lowId), uint24(highId));
    }

    /// @notice Preserve owner consent after a partial withdrawal, narrowing
    /// the range to bins that still hold shares. Clear it only when empty.
    function syncAfterOwnerWithdrawal(
        BinKey calldata key
    ) external {
        _requireOwnerStrategy();
        bytes32 hash = keccak256(abi.encode(key));
        BinSettings storage settings = settingsMap[hash];
        uint256 low = type(uint24).max;
        uint256 high;
        for (uint256 id = settings.rangeLow; id <= settings.rangeHigh; ++id) {
            if (!isBurnable(
                    key.lbPair,
                    id,
                    key.lbPair.balanceOf(address(key.sickle), id)
                )) continue;
            if (id < low) low = id;
            high = id;
        }
        if (low == type(uint24).max) {
            delete settingsMap[hash];
            emit BinSettingsCleared(key);
        } else {
            uint256 oldWidth = uint256(settings.rangeHigh) - settings.rangeLow;
            settings.rangeLow = uint24(low);
            settings.rangeHigh = uint24(high);
            if (
                settings.autoRebalance && settings.shiftConfig.enabled
                    && uint256(high) - low != oldWidth
            ) {
                settings.autoRebalance = false;
                settings.shiftConfig.enabled = false;
                emit BinSettingsSet(key, settings);
            }
            emit BinRangeUpdated(key, uint24(low), uint24(high));
        }
    }

    function _requireOwnerStrategy() private view {
        if (msg.sender != strategy && msg.sender != bridgeStrategy) {
            revert OnlyStrategy();
        }
    }

    function _validateIds(
        BinSettings memory settings,
        uint256[] calldata ids
    ) private pure {
        if (ids.length == 0) revert InvalidRange();
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] < settings.rangeLow || ids[i] > settings.rangeHigh) {
                revert BinOutsideRange(ids[i]);
            }
        }
    }

    function _lower(
        uint24 rangeLow,
        uint24 buffer
    ) private pure returns (uint256) {
        return rangeLow > buffer ? rangeLow - buffer : 0;
    }
}
