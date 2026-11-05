// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ICurveMinter
} from "contracts/interfaces/external/curve/ICurveMinter.sol";

interface ICurveLiquidityGauge {
    function period() external view returns (int128);
    function period_timestamp(
        uint256 index
    ) external view returns (uint256);
    function integrate_inv_supply(
        uint256 index
    ) external view returns (uint256);
    function integrate_inv_supply_of(
        address user
    ) external view returns (uint256);
    function integrate_fraction(
        address user
    ) external view returns (uint256);
    function working_balances(
        address user
    ) external view returns (uint256);
    function working_supply() external view returns (uint256);
    function inflation_rate() external view returns (uint256);
    function future_epoch_time() external view returns (uint256);
    function is_killed() external view returns (bool);
}

interface ICurveGaugeController {
    function gauge_types(
        address gauge
    ) external view returns (int128);
    function points_weight(
        address gauge,
        uint256 time
    ) external view returns (uint256 bias, uint256 slope);
    function time_weight(
        address gauge
    ) external view returns (uint256);
    function points_total(
        uint256 time
    ) external view returns (uint256);
    function points_type_weight(
        int128 gaugeType,
        uint256 time
    ) external view returns (uint256);
}

interface ICurveToken {
    function rate() external view returns (uint256);
}

/// @title Read-only claimable CRV for a Curve liquidity gauge.
///
/// @notice Curve's own `claimable_tokens` is the authoritative figure, but it
/// checkpoints the gauge and the GaugeController as it reads, so it is not a
/// `view` and `IFarmConnector.earned` cannot call it. This reproduces its
/// arithmetic from public state instead: `LiquidityGaugeV6._checkpoint`, plus
/// the slice of `GaugeController._get_weight` that `_checkpoint` triggers via
/// `checkpoint_gauge`.
///
/// @dev Two inputs are unreachable, both private mappings with no getter on
/// the GaugeController: `changes_weight`, which `_get_weight` uses to retire
/// the gauge's vote slope at each week boundary, and `changes_sum`, which
/// `_get_sum` needs to extend `points_total` past `time_total`. Neither can be
/// read from another contract, so exactness has a horizon rather than being a
/// matter of effort.
///
/// Inside that horizon the result is exact. Past it the accrual stops rather
/// than drifting, because `points_total` reads zero for an unfilled week and a
/// zero weight contributes nothing. Measured against the real
/// `claimable_tokens` on a frozen fork, where nothing else advances the
/// controller (see CurveCrvRewards.t.sol):
///
///   1 week   exact, to the wei
///   2 weeks  110 bps low
///   3 weeks  3407 bps low
///   6 weeks  6704 bps low
///
/// A live chain does not sit still like that: `time_total` is pushed forward
/// by activity on any Curve gauge, and `time_weight` for this gauge by any
/// interaction with it, so the horizon is continuously refreshed and the
/// common case is the exact one.
///
/// Every failure mode here under-reports; none over-reports. Both unread
/// mappings are non-negative and only ever remove weight, and an unfilled week
/// contributes zero. That direction is deliberate -- see PangolinEarned, where
/// reconstructing a reward formula overstated by 108x. A reward that reads low
/// is a display shortfall; one that reads high invites a strategy to act on
/// rewards that are not there.
library CurveCrvRewards {
    uint256 private constant WEEK = 604_800;
    uint256 private constant MULTIPLIER = 10 ** 18;
    uint256 private constant MAX_WEEKS = 500;

    /// @notice CRV that `Minter.mint(gauge)` would pay `user`, exact while the
    /// GaugeController is checkpointed through the elapsed weeks and a strict
    /// lower bound past that. See the horizon note on this library: a week the
    /// controller has not filled contributes zero, so the figure plateaus
    /// rather than drifting, and never exceeds what a claim pays.
    function claimable(
        address gauge,
        address user,
        address controller,
        address minter,
        address crv
    ) internal view returns (uint256) {
        ICurveLiquidityGauge g = ICurveLiquidityGauge(gauge);

        int128 currentPeriod = g.period();
        uint256 periodIndex = uint256(uint128(currentPeriod));
        uint256 periodTime = g.period_timestamp(periodIndex);
        uint256 integrateInvSupply = g.integrate_inv_supply(periodIndex);

        integrateInvSupply += _accrued(g, gauge, controller, crv, periodTime);

        uint256 integrateInvSupplyOf = g.integrate_inv_supply_of(user);
        if (integrateInvSupply < integrateInvSupplyOf) {
            // The user is ahead of the period integral; nothing new accrued.
            return _unminted(g.integrate_fraction(user), user, gauge, minter);
        }

        uint256 fraction = g.integrate_fraction(user) + g.working_balances(user)
            * (integrateInvSupply - integrateInvSupplyOf) / MULTIPLIER;

        return _unminted(fraction, user, gauge, minter);
    }

    /// @dev The `block.timestamp > _period_time` branch of `_checkpoint`: walk
    /// week by week from the last checkpoint, accumulating rate * weight * dt
    /// over the working supply, and switching rate where a CRV emission epoch
    /// falls inside a week.
    function _accrued(
        ICurveLiquidityGauge g,
        address gauge,
        address controller,
        address crv,
        uint256 periodTime
    ) private view returns (uint256 integrateInvSupply) {
        if (block.timestamp <= periodTime) {
            return 0;
        }

        uint256 workingSupply = g.working_supply();
        if (workingSupply == 0) {
            return 0;
        }

        bool killed = g.is_killed();
        uint256 prevFutureEpoch = g.future_epoch_time();
        uint256 rate = killed ? 0 : g.inflation_rate();
        uint256 newRate = rate;
        if (!killed && prevFutureEpoch >= periodTime) {
            newRate = ICurveToken(crv).rate();
        }

        uint256 prevWeekTime = periodTime;
        uint256 weekTime =
            _min((periodTime + WEEK) / WEEK * WEEK, block.timestamp);

        for (uint256 i; i < MAX_WEEKS; i++) {
            uint256 weight = _relativeWeight(controller, gauge, prevWeekTime);

            if (prevFutureEpoch >= prevWeekTime && prevFutureEpoch < weekTime) {
                integrateInvSupply += rate * weight
                    * (prevFutureEpoch - prevWeekTime) / workingSupply;
                rate = newRate;
                integrateInvSupply += rate * weight
                    * (weekTime - prevFutureEpoch) / workingSupply;
            } else {
                integrateInvSupply += rate * weight * (weekTime - prevWeekTime)
                    / workingSupply;
            }

            if (weekTime == block.timestamp) {
                break;
            }
            prevWeekTime = weekTime;
            weekTime = _min(weekTime + WEEK, block.timestamp);
        }
    }

    /// @dev `GaugeController._gauge_relative_weight`, reading the gauge bias
    /// through the fill-forward that `checkpoint_gauge` would have applied.
    function _relativeWeight(
        address controller,
        address gauge,
        uint256 time
    ) private view returns (uint256) {
        ICurveGaugeController c = ICurveGaugeController(controller);

        uint256 weekStart = time / WEEK * WEEK;
        uint256 totalWeight = c.points_total(weekStart);
        if (totalWeight == 0) {
            return 0;
        }

        uint256 typeWeight =
            c.points_type_weight(c.gauge_types(gauge), weekStart);
        uint256 gaugeWeight = _gaugeBias(c, gauge, weekStart);

        return MULTIPLIER * typeWeight * gaugeWeight / totalWeight;
    }

    /// @dev `GaugeController._get_weight`, without the state writes and
    /// without `changes_weight` -- see the note on this library.
    function _gaugeBias(
        ICurveGaugeController c,
        address gauge,
        uint256 target
    ) private view returns (uint256) {
        uint256 checkpointed = c.time_weight(gauge);
        if (checkpointed == 0) {
            return 0;
        }
        if (target <= checkpointed) {
            (uint256 storedBias,) = c.points_weight(gauge, target);
            return storedBias;
        }

        (uint256 bias, uint256 slope) = c.points_weight(gauge, checkpointed);

        uint256 t = checkpointed;
        for (uint256 i; i < MAX_WEEKS && t < target; i++) {
            t += WEEK;
            uint256 decay = slope * WEEK;
            if (bias > decay) {
                bias -= decay;
            } else {
                return 0;
            }
        }
        return bias;
    }

    function _unminted(
        uint256 fraction,
        address user,
        address gauge,
        address minter
    ) private view returns (uint256) {
        uint256 minted = ICurveMinter(minter).minted(user, gauge);
        return fraction > minted ? fraction - minted : 0;
    }

    function _min(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        return a < b ? a : b;
    }

    // Preserve the deployed five-argument path above for existing consumers.
    function claimable(
        address gauge,
        address user,
        address controller,
        address minter,
        address crv,
        bool killed
    ) internal view returns (uint256) {
        ICurveLiquidityGauge g = ICurveLiquidityGauge(gauge);

        int128 currentPeriod = g.period();
        uint256 periodIndex = uint256(uint128(currentPeriod));
        uint256 periodTime = g.period_timestamp(periodIndex);
        uint256 integrateInvSupply = g.integrate_inv_supply(periodIndex);

        integrateInvSupply += _accruedWithKillState(
            g, gauge, controller, crv, periodTime, killed
        );

        return _unminted(
            _fraction(g, user, integrateInvSupply), user, gauge, minter
        );
    }

    function _fraction(
        ICurveLiquidityGauge g,
        address user,
        uint256 integrateInvSupply
    ) private view returns (uint256) {
        uint256 integrateInvSupplyOf = g.integrate_inv_supply_of(user);
        if (integrateInvSupply < integrateInvSupplyOf) {
            // The user is ahead of the period integral; nothing new accrued.
            return g.integrate_fraction(user);
        }
        return g.integrate_fraction(user) + g.working_balances(user)
            * (integrateInvSupply - integrateInvSupplyOf) / MULTIPLIER;
    }

    function _accruedWithKillState(
        ICurveLiquidityGauge g,
        address gauge,
        address controller,
        address crv,
        uint256 periodTime,
        bool killed
    ) private view returns (uint256 integrateInvSupply) {
        if (block.timestamp <= periodTime) {
            return 0;
        }

        uint256 workingSupply = g.working_supply();
        if (workingSupply == 0) {
            return 0;
        }

        uint256 prevFutureEpoch = g.future_epoch_time();
        uint256 rate = killed ? 0 : g.inflation_rate();
        uint256 newRate = rate;
        if (!killed && prevFutureEpoch >= periodTime) {
            newRate = ICurveToken(crv).rate();
        }

        uint256 prevWeekTime = periodTime;
        uint256 weekTime =
            _min((periodTime + WEEK) / WEEK * WEEK, block.timestamp);

        for (uint256 i; i < MAX_WEEKS; i++) {
            uint256 weight = _relativeWeight(controller, gauge, prevWeekTime);

            if (prevFutureEpoch >= prevWeekTime && prevFutureEpoch < weekTime) {
                integrateInvSupply += rate * weight
                    * (prevFutureEpoch - prevWeekTime) / workingSupply;
                rate = newRate;
                integrateInvSupply += rate * weight
                    * (weekTime - prevFutureEpoch) / workingSupply;
            } else {
                integrateInvSupply += rate * weight * (weekTime - prevWeekTime)
                    / workingSupply;
            }

            if (weekTime == block.timestamp) {
                break;
            }
            prevWeekTime = weekTime;
            weekTime = _min(weekTime + WEEK, block.timestamp);
        }
    }
}
