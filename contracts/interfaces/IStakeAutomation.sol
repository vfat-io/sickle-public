// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

/// @title IStakeAutomation
/// @notice Directional keeper entrypoints for the Aerodrome Slipstream
/// stake-mode auto-flip, dispatched through `Automation.executeFor`. Each takes
/// the Sickle first (executeFor binds it to the calldata's leading argument)
/// and is bound to its own permission bit (STAKE_STAKE / STAKE_UNSTAKE)
/// via `Automation.setActionPermission`. The keeper has no discretion: the
/// strategy re-derives the emission-vs-fee ratio R on-chain and only flips
/// once the favored signal has held the dwell.
interface IStakeAutomation {
    /// @notice Poke toward restaking a currently-unstaked position: re-derive R
    /// and restake once emissions reclaim the lead (R <= thetaDown) and the
    /// candidate has held the dwell. A no-op while the signal is forming.
    function stakeFor(Sickle sickle, NftPosition calldata position) external;

    /// @notice Poke toward unstaking a currently-staked position: re-derive R
    /// and unstake once fees clear the unstake bar (R >= thetaUp) and the
    /// candidate has held the dwell. A no-op while the signal is forming.
    function unstakeFor(Sickle sickle, NftPosition calldata position) external;
}
