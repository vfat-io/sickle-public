// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ZapIn } from "contracts/structs/ZapStructs.sol";
import {
    HarvestParams,
    WithdrawParams
} from "contracts/structs/FarmStrategyStructs.sol";

/// @param pool The pool, which is also its BPT.
/// @param gauge Where the BPT is staked, or `address(0)` to keep it in the
/// Sickle.
struct BalancerPosition {
    address pool;
    address gauge;
}

/// @param position Target position.
/// @param tokensIn Tokens pulled from the owner (`ETH` sentinel for native).
/// @param amountsIn Amounts pulled, per `tokensIn`.
/// @param zap Optional swaps, then the add: `addLiquidityParams.lpToken`
/// must be `position.pool`, `router` the registered Balancer V3 router.
/// @param gaugeExtraData Passed to the gauge connector's `deposit` (ignored
/// for an unstaked position).
struct BalancerDepositParams {
    BalancerPosition position;
    address[] tokensIn;
    uint256[] amountsIn;
    ZapIn zap;
    bytes gaugeExtraData;
}

/// @param position Target position.
/// @param bptAmount BPT pulled from the owner.
/// @param gaugeExtraData Passed to the gauge connector's `deposit`.
struct BalancerSimpleDepositParams {
    BalancerPosition position;
    uint256 bptAmount;
    bytes gaugeExtraData;
}

/// @param claimExtraData Passed to the gauge connector's `claim`.
/// @param rewardTokens Claimed tokens, charged the compound fee.
/// @param zap Swaps of the rewards, then the add into `position.pool`.
/// @param gaugeExtraData Passed to the gauge connector's `deposit`.
struct BalancerCompoundParams {
    bytes claimExtraData;
    address[] rewardTokens;
    ZapIn zap;
    bytes gaugeExtraData;
}

/// @notice ABI-encoded into `PositionSettings.extraData` (empty = all off).
/// @param autoDeposit Lets the approved keeper call `depositFor`, as
/// `NftSettings.autoDeposit` does.
struct BalancerPositionOptions {
    bool autoDeposit;
}

/// @notice Move a whole position to another `(pool, gauge)`.
/// @param from Source position; always exited in full.
/// @param harvest Source rewards (gauged source only).
/// @param harvestSweepTokens Swept to the owner after the harvest.
/// @param withdraw Source liquidity exit (`lpAmountIn` is ignored: the whole
/// position moves). Unused when `to.pool == from.pool`.
/// @param to Target position.
/// @param zap Swaps, then the add into `to.pool`. Unused when
/// `to.pool == from.pool`: the BPT is only restaked, never round-tripped.
/// @param gaugeExtraData Passed to `to.gauge`'s connector `deposit`.
struct BalancerMoveParams {
    BalancerPosition from;
    HarvestParams harvest;
    address[] harvestSweepTokens;
    WithdrawParams withdraw;
    BalancerPosition to;
    ZapIn zap;
    bytes gaugeExtraData;
}
