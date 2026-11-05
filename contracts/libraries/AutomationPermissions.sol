// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title AutomationPermissions
/// @notice Named permission bits for the Automation contract. The legacy
/// typed entrypoints use the fixed bits below; the generic `executeFor`
/// dispatch binds each (strategy, selector) pair to a bit via
/// `Automation.setActionPermission`. New automation categories (vaults,
/// lending, ...) claim higher bits as data — there is no compile-time upper
/// bound, so adding one needs no Automation redeploy or per-Sickle migration.
library AutomationPermissions {
    uint256 internal constant FARM_HARVEST = 1 << 0;
    uint256 internal constant FARM_COMPOUND = 1 << 1;
    uint256 internal constant FARM_EXIT = 1 << 2;
    uint256 internal constant NFT_HARVEST = 1 << 3;
    uint256 internal constant NFT_COMPOUND = 1 << 4;
    uint256 internal constant NFT_EXIT = 1 << 5;
    uint256 internal constant NFT_REBALANCE = 1 << 6;
    uint256 internal constant NFT_DUST_DEPOSIT = 1 << 7;
    uint256 internal constant MULTI_COMPOUND = 1 << 8;
    uint256 internal constant BASIS_DELEVERAGE = 1 << 9;
    uint256 internal constant BASIS_REBALANCE = 1 << 10;
    uint256 internal constant BASIS_HARVEST = 1 << 11;
    uint256 internal constant BASIS_COMPOUND = 1 << 12;
    uint256 internal constant BASIS_EXIT = 1 << 13;
    uint256 internal constant BASIS_CANCEL_ORDER = 1 << 14;
    // Aerodrome Slipstream stake-mode auto-flip (StakeStrategy). Two bits
    // so an owner can consent to auto-unstake without auto-stake (or vice
    // versa); bound to the strategy's stakeFor / unstakeFor selectors via
    // Automation.setActionPermission and dispatched through executeFor.
    uint256 internal constant STAKE_STAKE = 1 << 15;
    uint256 internal constant STAKE_UNSTAKE = 1 << 16;
    /// @dev Generic `executeFor` permission for an ordinary Sickle rebalance.
    /// Typed callback-owning vaults consent to NFT_REBALANCE instead and do
    /// not receive this bit, so their callback-safe route cannot be bypassed.
    uint256 internal constant NFT_REBALANCE_GENERIC = 1 << 17;
    uint256 internal constant BIN_HARVEST = 1 << 18;
    uint256 internal constant BIN_COMPOUND = 1 << 19;
    uint256 internal constant BIN_EXIT = 1 << 20;
    uint256 internal constant BIN_REBALANCE = 1 << 21;
    uint256 internal constant BIN_DUST_DEPOSIT = 1 << 22;
    /// @dev Keeper deposit into an existing ERC20 (BalancerStrategy BPT)
    /// position the owner opted into auto-deposit for; the ERC20 analogue of
    /// NFT_DUST_DEPOSIT. Bits 18-22 are taken by the Liquidity Book bin
    /// strategy's categories.
    uint256 internal constant FARM_DEPOSIT = 1 << 23;
    /// @dev Keeper vote of a Sickle's voting-escrow NFTs
    /// (VotingEscrowStrategy.voteFor). Their rewards reuse FARM_HARVEST and
    /// FARM_COMPOUND.
    uint256 internal constant VE_VOTE = 1 << 24;
    /// @dev Grant-everything default for `setApprovedAutomator`. Not a hard
    /// cap: permission masks are free-form uint256 so future category bits
    /// can be granted without redeploying Automation.
    uint256 internal constant ALL = type(uint256).max;
}
