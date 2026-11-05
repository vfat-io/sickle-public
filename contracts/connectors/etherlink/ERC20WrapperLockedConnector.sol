// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IERC20
} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";

/// @notice Minimal interface for Euler's `ERC20WrapperLocked` reward wrappers
/// (e.g. Apple Farm's `appl*` tokens on Etherlink). These wrappers are
/// non-transferrable between non-whitelisted accounts; a non-whitelisted holder
/// such as a Sickle can only realise the reward by redeeming the underlying as
/// per the lock schedule.
interface IERC20WrapperLocked {
    /// @notice Redeems the underlying token for the given normalized lock
    /// timestamps as per the lock schedule. The unvested remainder is forfeited
    /// to the wrapper's configured receiver when `allowRemainderLoss` is true;
    /// otherwise the call reverts if any remainder would be lost.
    function withdrawToByLockTimestamps(
        address account,
        uint256[] memory lockTimestamps,
        bool allowRemainderLoss
    ) external returns (bool);

    /// @notice All normalized lock timestamps with a locked balance for
    /// `account`.
    function getLockedAmountsLockTimestamps(
        address account
    ) external view returns (uint256[] memory);

    /// @notice Currently redeemable (`accountAmount`) and forfeitable
    /// (`remainderAmount`) underlying for a single lock timestamp.
    function getWithdrawAmountsByLockTimestamp(
        address account,
        uint256 lockTimestamp
    ) external view returns (uint256 accountAmount, uint256 remainderAmount);
}

/// @title ERC20WrapperLockedConnector
/// @notice Farm connector that redeems Euler `ERC20WrapperLocked` reward
/// wrappers (Apple Farm `appl*` tokens on Etherlink) held by a Sickle into
/// their underlying token.
/// @dev Modelled as a claim, not a withdraw: the locked wrapper accrues in the
/// Sickle from the upstream Merkl reward claim (it cannot be transferred or
/// swept while locked), and `claim` here redeems every lock the Sickle holds
/// into the underlying so the FarmStrategy harvest flow can charge fees on the
/// transferrable underlying and sweep it to the user. The wrapper itself is the
/// farm's `stakingContract`.
///
/// `claim` takes no `extraData` and applies no vesting filter. It redeems all
/// locks with `allowRemainderLoss = true`: a partially-vested lock is redeemed
/// at its current vested share and the unvested remainder is forfeited per the
/// wrapper's lock schedule. Vesting only ever increases with time, so a caller
/// that wants the full amount simply waits and does not call; a caller that
/// accepts an early-exit haircut calls now. The choice is the caller's to make
/// off-chain — the connector does not second-guess it.
///
/// `deposit`/`withdraw` are unsupported: the wrapper only arrives via the
/// reward distribution and only leaves as the underlying.
contract ERC20WrapperLockedConnector is IFarmConnector {
    /// @notice Thrown when `deposit` or `withdraw` is called: the locked
    /// wrapper is not a stakeable position.
    error NotSupported();

    /// @inheritdoc IFarmConnector
    function deposit(
        Farm calldata,
        address,
        bytes memory
    ) external pure override {
        revert NotSupported();
    }

    /// @inheritdoc IFarmConnector
    function withdraw(
        Farm calldata,
        uint256,
        bytes memory
    ) external pure override {
        revert NotSupported();
    }

    /// @notice Redeems every lock the Sickle holds in the wrapper into the
    /// underlying token. The underlying stays in the Sickle for the harvest fee
    /// and sweep steps that follow in the FarmStrategy multicall. Unvested
    /// portions are forfeited per the wrapper's lock schedule.
    /// @param farm `farm.stakingContract` is the `ERC20WrapperLocked` wrapper.
    function claim(
        Farm calldata farm,
        bytes memory // extraData
    ) external override {
        IERC20WrapperLocked wrapper = IERC20WrapperLocked(farm.stakingContract);

        // Connectors run via delegatecall, so `address(this)` is the Sickle:
        // the lock owner and the destination for the redeemed underlying.
        uint256[] memory lockTimestamps =
            wrapper.getLockedAmountsLockTimestamps(address(this));

        if (lockTimestamps.length == 0) {
            return;
        }

        wrapper.withdrawToByLockTimestamps(address(this), lockTimestamps, true);
    }

    /// @notice The Sickle's locked wrapper balance.
    /// @inheritdoc IFarmConnector
    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IERC20(farm.stakingContract).balanceOf(user);
    }

    /// @notice Currently redeemable underlying summed across all of the
    /// Sickle's locks, reported as the first reward token amount.
    /// @inheritdoc IFarmConnector
    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](rewardTokens.length);
        if (rewardTokens.length == 0) {
            return amounts;
        }

        IERC20WrapperLocked wrapper = IERC20WrapperLocked(farm.stakingContract);
        uint256[] memory lockTimestamps =
            wrapper.getLockedAmountsLockTimestamps(user);

        uint256 redeemable;
        for (uint256 i; i < lockTimestamps.length; i++) {
            (uint256 accountAmount,) = wrapper.getWithdrawAmountsByLockTimestamp(
                user, lockTimestamps[i]
            );
            redeemable += accountAmount;
        }
        amounts[0] = redeemable;
        return amounts;
    }

    /// @notice The locked wrapper is held by the Sickle, not staked elsewhere.
    /// @inheritdoc IFarmConnector
    function isStaked(
        Farm calldata,
        address
    ) external pure override returns (bool) {
        return false;
    }
}
