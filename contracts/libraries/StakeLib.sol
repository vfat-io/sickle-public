// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IUniswapV3Pool
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {
    TickMath
} from "contracts/interfaces/external/uniswap/v3/libraries/TickMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ICLPool } from "contracts/interfaces/external/aerodrome/ICLPool.sol";
import { ICLGauge } from "contracts/interfaces/external/aerodrome/ICLGauge.sol";
import { IStakeLib } from "contracts/interfaces/libraries/IStakeLib.sol";

/// @title StakeLib
/// @notice On-chain comparison of a Slipstream CL position's emission APR (when
/// staked in the gauge) vs swap-fee APR (when unstaked), used to gate the vault's
/// stake/unstake flip. The keeper has NO discretion: the chain re-derives the
/// condition here, mirroring how `validateRebalanceFor` re-derives the tick
/// trigger. Emission APR is FORWARD (current gauge `rewardRate` x the position's
/// in-range staked share); fee APR is the REALIZED rate over the window since the
/// last snapshot. Everything reduces to token1 via the pool's own TWAP plus a
/// caller-supplied AERO->token1 TWAP price — no external oracle.
/// @dev A normal helper contract (the repo's `*Lib` pattern: SwapLib, ShiftMath,
/// …), NOT a compiler-linked library — deployed once per chain and called via
/// {IStakeLib} so `StakeStrategy` stays under EIP-170 and the math is verified
/// independently. The `Inputs`/`Snapshot` structs live in {IStakeLib}.
contract StakeLib is IStakeLib {
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant Q96 = 1 << 96;

    /// @notice Computes the unstaked/staked yield ratio R and the threshold
    /// signals. R = (net unstaked fee APR) / (staked emission APR), in bps. The
    /// caller (vault) applies the dwell: only flip after the favored signal has
    /// persisted, re-deriving this each poke — so the keeper decides nothing.
    /// @return ratioBps R x 10000 (type(uint256).max when emission APR is 0)
    /// @return favorUnstake R >= thetaUp — fees clear the unstake bar
    /// @return favorStake R <= thetaDown — emissions reclaim the lead
    /// @return feeAprBpsNet net (post-unstakedFee) fee APR, bps
    /// @return emissionAprBps forward emission APR, bps
    function evaluate(
        Inputs memory p,
        Snapshot memory last
    )
        external
        view
        override
        returns (
            uint256 ratioBps,
            bool favorUnstake,
            bool favorStake,
            uint256 feeAprBpsNet,
            uint256 emissionAprBps
        )
    {
        feeAprBpsNet = _feeAprBps(p, last);
        emissionAprBps = _emissionAprBps(p);
        ratioBps = emissionAprBps == 0
            ? type(uint256).max
            : Math.mulDiv(feeAprBpsNet, BPS, emissionAprBps);
        favorUnstake = ratioBps >= p.thetaUpBps;
        favorStake = ratioBps <= p.thetaDownBps;
    }

    /// @dev Realized fee APR over the window: Δ feeGrowthInside x liquidity, in
    /// token1 (token0 leg converted at the TWAP price), annualized over the
    /// window. Inside (not global) growth, so out-of-range windows contribute
    /// zero — the position is credited only the fees it actually earned.
    function _feeAprBps(
        Inputs memory p,
        Snapshot memory last
    ) private view returns (uint256) {
        uint256 dt = block.timestamp - last.timestamp;
        if (dt == 0 || p.positionValueToken1 == 0) return 0;
        (uint256 inside0, uint256 inside1) =
            _feeGrowthInside(p.pool, p.tickLower, p.tickUpper);
        // Inside growth is non-monotonic (feeGrowthOutside flips on tick
        // crossings), so the raw subtraction can underflow; modulo 2**256 the
        // delta is the true in-range accrual over the window (zero out of
        // range), so difference unchecked — matching UniV3 Position accounting.
        uint256 d0;
        uint256 d1;
        unchecked {
            d0 = inside0 - last.feeGrowthInside0X128;
            d1 = inside1 - last.feeGrowthInside1X128;
        }
        uint256 fee0 = Math.mulDiv(d0, p.liquidity, Q128);
        uint256 fee1 = Math.mulDiv(d1, p.liquidity, Q128);
        uint160 sqrtP =
            TickMath.getSqrtRatioAtTick(_twapTick(p.pool, p.twapWindow));
        // token0 -> token1 at TWAP: amount0 * (sqrtP / 2**96)**2
        uint256 fee0InToken1 =
            Math.mulDiv(Math.mulDiv(fee0, sqrtP, Q96), sqrtP, Q96);
        // the LP keeps only (1 - unstakedFee) of swap fees when unstaked
        uint256 incomeToken1 = Math.mulDiv(
            fee1 + fee0InToken1, BPS - p.unstakedFeeBps, BPS
        );
        return Math.mulDiv(
            incomeToken1 * SECONDS_PER_YEAR, BPS, dt * p.positionValueToken1
        );
    }

    /// @notice Fee growth (X128) accrued strictly inside [tickLower, tickUpper]
    /// for each token, the standard Uniswap V3 identity
    /// `global - below(lower) - above(upper)`. Unlike `feeGrowthGlobal` it only
    /// advances while the price is in range, so its delta x liquidity is the
    /// position's ACTUAL swap fees (zero out of range). The vault snapshots this
    /// each harvest into {Snapshot} in place of the global growth.
    /// @dev All arithmetic wraps mod 2**256 (UniV3 semantics): feeGrowthOutside
    /// flips on tick crossings, so these terms are not individually monotonic.
    /// Snapshots are comparable only while the range is fixed.
    function feeGrowthInside(
        address pool,
        int24 tickLower,
        int24 tickUpper
    ) external view override returns (uint256 inside0, uint256 inside1) {
        return _feeGrowthInside(pool, tickLower, tickUpper);
    }

    function _feeGrowthInside(
        address pool,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (uint256 inside0, uint256 inside1) {
        ICLPool p = ICLPool(pool);
        (, int24 tickCurrent,,,,) = p.slot0();
        (,,, uint256 lo0, uint256 lo1,,,,,) = p.ticks(tickLower);
        (,,, uint256 up0, uint256 up1,,,,,) = p.ticks(tickUpper);
        uint256 g0 = p.feeGrowthGlobal0X128();
        uint256 g1 = p.feeGrowthGlobal1X128();
        unchecked {
            // below the lower tick: feeGrowthOutside(lower) when the price is
            // at/above it, else global minus that.
            uint256 below0 = tickCurrent >= tickLower ? lo0 : g0 - lo0;
            uint256 below1 = tickCurrent >= tickLower ? lo1 : g1 - lo1;
            // above the upper tick: feeGrowthOutside(upper) when below it, else
            // global minus that.
            uint256 above0 = tickCurrent < tickUpper ? up0 : g0 - up0;
            uint256 above1 = tickCurrent < tickUpper ? up1 : g1 - up1;
            inside0 = g0 - below0 - above0;
            inside1 = g1 - below1 - above1;
        }
    }

    /// @dev Forward emission APR: gauge `rewardRate` x (liquidity / in-range staked
    /// liquidity), priced to token1, annualized. When not currently staked, the
    /// share denominator includes our own liquidity (the dilution we'd add).
    function _emissionAprBps(Inputs memory p) private view returns (uint256) {
        if (p.positionValueToken1 == 0) return 0;
        uint256 rewardRate = ICLGauge(p.gauge).rewardRate(); // AERO wei/sec, gauge
        uint128 stakedL = ICLPool(p.pool).stakedLiquidity();
        uint256 denom =
            p.currentlyStaked ? stakedL : uint256(stakedL) + p.liquidity;
        if (denom == 0) return 0;
        uint256 aeroPerSec = Math.mulDiv(rewardRate, p.liquidity, denom);
        uint256 incomeToken1PerSec =
            Math.mulDiv(aeroPerSec, p.aeroPriceToken1, 1e18);
        return Math.mulDiv(
            incomeToken1PerSec * SECONDS_PER_YEAR, BPS, p.positionValueToken1
        );
    }

    function _twapTick(
        address pool,
        uint32 window
    ) private view returns (int24 arithmeticMeanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) =
            IUniswapV3Pool(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 win = int56(uint56(window));
        arithmeticMeanTick = int24(delta / win);
        if (delta < 0 && (delta % win != 0)) arithmeticMeanTick--;
    }
}
