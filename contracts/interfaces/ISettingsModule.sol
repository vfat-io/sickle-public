// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { NftKey } from "contracts/structs/NftSettingsStructs.sol";

/// @title ISettingsModule
/// @notice A pluggable per-position settings store. Modules let a new
/// automation feature add its own typed settings without changing the core
/// `NftSettings` struct (and so without redeploying `NftSettingsRegistry` on
/// every chain). A module is registered with `NftSettingsRegistry`, which
/// calls `onRebalance` on every registered module whenever a rebalance moves
/// a position to a new `tokenId` — so a module keying state by `NftKey` gets
/// migration for free, without wiring its own hook into the rebalance path.
interface ISettingsModule {
    /// @notice Migrate any per-position state keyed by `oldKey` to `newKey`.
    /// @dev Called only by `NftSettingsRegistry`, from within
    /// `transferNftSettings`, when a rebalance changes a position's `tokenId`.
    /// `oldKey` and `newKey` share the same `sickle` and `nftManager` and
    /// differ only in `tokenId`. A module with no state for `oldKey` must
    /// treat the call as a no-op.
    function onRebalance(
        NftKey calldata oldKey,
        NftKey calldata newKey
    ) external;
}
