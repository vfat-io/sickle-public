// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Standalone cumulative Merkle distributor that pays the weekly
///         Fables USDG incentive.
/// @dev This is *not* the ve(3,3) fee-to-voters path: `distributor()` returns
///      `address(0)` on every deployed Fables hook, so hook-side emissions are
///      dormant until Fables' TGE. The weekly incentive instead runs through
///      this contract, whose leaves are published as a static JSON file and
///      re-rooted every week by `setRoot`.
///
///      Two properties shape the connector around it:
///      - Leaves are CUMULATIVE. `claimed[account]` records what has been paid
///        out, so one call with the newest proof settles every past week. There
///        is no per-week loop and no backfill.
///      - `claim` is PERMISSIONLESS. `account` is an explicit argument and the
///        payout goes to `account`, not to `msg.sender`, so a Sickle's
///        entitlement can be collected by the Sickle itself or by a keeper.
///
///      The credited address is the LP, which for vfat positions is the Sickle
///      rather than the Sickle's owner.
interface IFablesRewardDistributor {
    /// @notice ERC20 paid out by this distributor (USDG, 6 decimals).
    function token() external view returns (address);

    /// @notice Index of the currently published tree.
    function week() external view returns (uint256);

    /// @notice Merkle root of the currently published tree.
    function root() external view returns (bytes32);

    /// @notice Cumulative amount already paid out to `account`.
    function claimed(
        address account
    ) external view returns (uint256);

    /// @notice Cumulative amount paid out across every account.
    function totalClaimed() external view returns (uint256);

    /// @notice Amount `account` could still collect with this leaf.
    /// @dev Returns 0 rather than reverting when the leaf does not verify
    ///      against the current root, which makes it safe to use as a
    ///      pre-flight guard for a proof that may have aged out.
    function claimable(
        address account,
        uint256 cumulativeAmount,
        bytes32[] calldata proof
    ) external view returns (uint256);

    /// @notice Pay `account` everything its leaf entitles it to and has not
    ///         already received.
    /// @dev Reverts with `InvalidProof()` (0x09bde339) when the leaf does not
    ///      verify against the current root, and with `NothingToClaim()`
    ///      (0x969bf728) when `claimed[account]` already covers the leaf. Both
    ///      are ordinary states for a caller holding a week-old proof, so
    ///      callers must guard rather than rely on a no-op.
    function claim(
        address account,
        uint256 cumulativeAmount,
        bytes32[] calldata proof
    ) external;
}
