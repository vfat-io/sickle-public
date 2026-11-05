// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { IUniswapV3Pool } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";

import { Sickle } from "contracts/Sickle.sol";
import { RewardConfig } from "contracts/structs/PositionSettingsStructs.sol";

struct NftKey {
    Sickle sickle;
    INonfungiblePositionManager nftManager;
    uint256 tokenId;
}

struct ExitConfig {
    int24 triggerTickLow;
    int24 triggerTickHigh;
    address exitTokenOutLow;
    address exitTokenOutHigh;
    uint256 priceImpactBP;
    uint256 slippageBP;
}

/**
 * @notice Settings for automatic rebalancing
 * @param tickSpacesBelow: Position width measured in tick spaces below
 * Default: 0 (Position doesn't include any tick spaces below current)
 * @param tickSpacesAbove: Position width measured in tick spaces above
 * Default: 0 (Position doesn't include any tick spaces above current)
 * @param bufferTicksBelow: Difference from position tickLower to
 * rebalance below. Can be negative (rebalance before position goes under
 * range)
 * Default: 0 (always rebalance if tick < tickLower)
 * @param bufferTicksAbove: Difference from position tickUpper to
 * rebalance above. Can be negative (rebalance before position goes above range)
 * Default: 0 (always rebalance if tick >= tickUpper)
 * @param dustBP: Dust allowance in basis points.
 * ADVISORY, NOT ENFORCED ON-CHAIN — see the note below.
 * @param priceImpactBP: Price impact allowance in basis points.
 * ADVISORY, NOT ENFORCED ON-CHAIN — see the note below.
 * @param slippageBP: Slippage allowance in basis points.
 * ADVISORY, NOT ENFORCED ON-CHAIN — see the note below.
 * @param cutoffTickLow: Stop rebalancing below this tick
 * default: MIN_TICK (no stop loss)
 * @param cutoffTickHigh: Stop rebalancing above this tick
 * default: MAX_TICK (no stop loss)
 * @param delayMin: Delay in minutes before rebalancing. Enforced off-chain
 * by the keeper; no contract reads this field.
 * @param rewardConfig: Configuration for handling rewards when rebalancing
 *
 * @dev ADVISORY FIELDS. `dustBP`, `priceImpactBP` and `slippageBP` are
 * range-checked by `NftSettingsRegistry._checkRebalanceConfig` when stored and
 * migrated with the position on rebalance, but NO execution path reads them.
 * `validateRebalanceFor` checks only the trigger and cutoff ticks;
 * `ShiftMath`'s pre- and post-mint checks bind the destination manager, pool
 * and — in shift mode — the exact tick range. The swap minimums that actually
 * bound a rebalance are the keeper's own `minAmountOut` and mint minimums, and
 * `AggregatorConnector` compares the returned amount against the same
 * keeper-supplied calldata. A replacement position can therefore satisfy every
 * on-chain check while holding materially less value than the original.
 *
 * They are kept as owner-facing policy that the keeper is expected to honour
 * off-chain, alongside `delayMin`. Enforcing them on-chain would need a
 * manipulation-resistant quote to derive minimums from, plus a requirement
 * that every swap output recipient is the executing Sickle — a larger change
 * than the fields imply. Do not read them as a guarantee.
 */
struct RebalanceConfig {
    uint24 tickSpacesBelow;
    uint24 tickSpacesAbove;
    int24 bufferTicksBelow;
    int24 bufferTicksAbove;
    uint256 dustBP;
    uint256 priceImpactBP;
    uint256 slippageBP;
    int24 cutoffTickLow;
    int24 cutoffTickHigh;
    uint8 delayMin;
    RewardConfig rewardConfig;
}

/**
 * Settings for automating an NFT position
 * @param autoRebalance: Whether to rebalance automatically when position goes
 * out of range
 * @param rebalanceConfig: Configuration for the above
 * @param automateRewards: Whether to automatically harvest or compound rewards
 * for this position, regardless of rebalance settings.
 * @param rewardConfig: Configuration for reward automation
 * Harvest as-is, harvest and convert to a different token, or compound into the
 * position.
 */
struct NftSettings {
    IUniswapV3Pool pool;
    bytes32 poolId;
    bool autoRebalance;
    RebalanceConfig rebalanceConfig;
    bool automateRewards;
    RewardConfig rewardConfig;
    bool autoExit;
    ExitConfig exitConfig;
    bytes extraData;
    bool autoDeposit;
}
