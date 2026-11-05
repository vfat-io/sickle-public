// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    StrategyModule,
    SickleFactory,
    Sickle
} from "contracts/modules/StrategyModule.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import {
    StakeSettingsRegistry,
    StakeConfig
} from "contracts/StakeSettingsRegistry.sol";
import { NftKey } from "contracts/structs/NftSettingsStructs.sol";
import {
    IStakeAutomation
} from "contracts/interfaces/IStakeAutomation.sol";
import { IStakeLib } from "contracts/interfaces/libraries/IStakeLib.sol";
import { ICLPool } from "contracts/interfaces/external/aerodrome/ICLPool.sol";
import {
    ICLPoolFactory
} from "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";
import { ICLGauge } from "contracts/interfaces/external/aerodrome/ICLGauge.sol";
import {
    IUniswapV3Pool
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {
    TickMath
} from "contracts/interfaces/external/uniswap/v3/libraries/TickMath.sol";
import {
    LiquidityAmounts
} from "contracts/interfaces/external/uniswap/v3/libraries/LiquidityAmounts.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StakeStrategy
/// @notice Drives an Aerodrome Slipstream ALM position between staked (earning
/// AERO emissions) and unstaked (earning swap fees) WITHOUT keeper discretion.
/// The keeper pokes a direction — `unstakeFor` (staked->unstaked) or `stakeFor`
/// (unstaked->staked) — and the contract re-derives the unstaked/staked yield
/// ratio R on-chain via {StakeLib}, advances or clears that direction's flip
/// candidate, and executes the flip only after the candidate has held the dwell
/// — mirroring the §2c backtest controller (default staked; unstake at
/// R>=thetaUp, restake at R<=thetaDown; 6h dwell). The keeper chooses nothing
/// the chain didn't verify; it cannot force a flip the ratio doesn't warrant.
/// @dev Dispatched through `Automation.executeFor`: each entrypoint is bound to
/// a permission bit (STAKE_STAKE / STAKE_UNSTAKE) via
/// `setActionPermission`, so the flip inherits Automation's owner consent
/// (`setActionConsent`), approved-automator allowlist and gas accounting; the
/// keeper itself is recorded by Automation's `AutomatedFor`. The position NFT
/// lives on the Sickle; staking is a gauge deposit/withdraw (no liquidity
/// change). Must be a whitelisted caller in the SickleRegistry to drive
/// `sickle.multicall`, like any strategy module.
contract StakeStrategy is StrategyModule, IStakeAutomation {
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant WAD = 1e18;
    // Bound the trailing fee window relative to its target so an absent or
    // over-eager keeper can't measure fees over a degenerate interval.
    uint256 private constant MIN_WINDOW_NUM = 1; // >= target/2
    uint256 private constant MIN_WINDOW_DEN = 2;
    uint256 private constant MAX_WINDOW_MULT = 3; // <= target*3

    error NotConfigured();
    error PositionMismatch();
    /// @dev `stakeFor`/`unstakeFor` called against the wrong current mode (you
    /// can only unstake a staked position and stake an unstaked one).
    error WrongMode();

    /// @dev Two fee-growth checkpoints form a ring: R is measured over
    /// [prev, now], and `curr` rolls into `prev` once it ages past the target,
    /// keeping the window in ~[target, 2*target] so every poke sees a stable
    /// trailing window (no noisy sub-window right after a roll). The checkpoints
    /// are `feeGrowthInside` for the position's range (not global), so they are
    /// comparable only while the range is fixed; a rebalance to a new range
    /// re-anchors the ring (see `anchorTick*` and `_anchor`).
    struct State {
        bool hasCandidate;
        bool candidateStaked; // the mode the candidate would switch TO
        uint32 candidateSince;
        // Range the checkpoints below were taken for; a poke at a different
        // range re-anchors (inside growth is range-specific). Packs with the
        // fields above into one slot.
        int24 anchorTickLower;
        int24 anchorTickUpper;
        uint256 prevFg0; // feeGrowthInside0 at prevAt, for the anchored range
        uint256 prevFg1; // feeGrowthInside1 at prevAt
        uint32 prevAt;
        uint256 currFg0; // feeGrowthInside0 at currAt
        uint256 currFg1; // feeGrowthInside1 at currAt
        uint32 currAt;
    }

    mapping(bytes32 => State) public stateOf;

    /// @notice Typed per-position policy store (an `ISettingsModule`). The vault
    /// (the Sickle owner) writes each position's {StakeConfig} via the
    /// registry's owner-keyed setter; the strategy only reads it — no bespoke
    /// config store, no owner-auth shim. Registered with `NftSettingsRegistry`,
    /// so a policy migrates on rebalance with the position's new tokenId.
    StakeSettingsRegistry public immutable stakeSettingsRegistry;

    /// @notice The deployed {StakeLib} math helper, called via interface so the
    /// strategy stays under EIP-170 (the repo's `*Lib` pattern; cf. ShiftMath).
    IStakeLib private immutable stakeLib;

    event StakePoked(
        bytes32 indexed key,
        uint256 ratioBps,
        bool favorUnstake,
        bool favorStake,
        bool currentlyStaked
    );
    event StakeFlipped(
        bytes32 indexed key, bool nowStaked, uint256 ratioBps
    );

    constructor(
        SickleFactory factory_,
        ConnectorRegistry connectorRegistry_,
        StakeSettingsRegistry stakeSettingsRegistry_,
        IStakeLib stakeLib_
    ) StrategyModule(factory_, connectorRegistry_) {
        stakeSettingsRegistry = stakeSettingsRegistry_;
        stakeLib = stakeLib_;
    }

    function _key(
        Sickle sickle,
        NftPosition calldata position
    ) private pure returns (bytes32) {
        // Keyed by (sickle, nftManager) — NOT tokenId — so the config + state
        // survive a rebalance (which mints a new tokenId; the vault's
        // onRebalance updates position.tokenId). The live tokenId is read from
        // the position arg at poke time. Assumes one stake-mode position per
        // (sickle, nft), which holds for the one-position-per-vault ALM design.
        return keccak256(abi.encode(address(sickle), address(position.nft)));
    }

    /// @dev Load the stake-mode {StakeConfig} from the settings registry.
    /// The vault (the Sickle owner) writes it via the registry's owner-keyed
    /// setter — see `NftFarmVault.setStakeConfig`, which validates the
    /// fields and sets `enabled`. Reverts {NotConfigured} when no policy is set
    /// (a zeroed slot reads `enabled == false`) or it was disabled.
    function _loadConfig(
        Sickle sickle,
        NftPosition calldata position
    ) private view returns (StakeConfig memory cfg) {
        cfg = stakeSettingsRegistry.getConfig(
            NftKey({
                sickle: sickle,
                nftManager: position.nft,
                tokenId: position.tokenId
            })
        );
        if (!cfg.enabled) revert NotConfigured();
    }

    /// @notice Keeper poke toward unstaking a staked position: re-derive R,
    /// advance/clear the unstake candidate, and unstake once it has held the
    /// dwell. A no-op while the candidate forms or the fee window is degenerate
    /// — the keeper can poll freely; the chain decides. Reverts {WrongMode} if
    /// the position is already unstaked. Sickle-first for `executeFor`.
    function unstakeFor(
        Sickle sickle,
        NftPosition calldata position
    ) external override onlyApproved(sickle) {
        _poke(sickle, position, false);
    }

    /// @notice Keeper poke toward restaking an unstaked position. Symmetric to
    /// {unstakeFor}: restakes once the restake candidate (R <= thetaDown) has
    /// held the dwell. Reverts {WrongMode} if the position is already staked.
    function stakeFor(
        Sickle sickle,
        NftPosition calldata position
    ) external override onlyApproved(sickle) {
        _poke(sickle, position, true);
    }

    /// @dev Shared directional poke. `wantStaked` is the mode this call drives
    /// toward and must differ from the current mode (checked below), so only
    /// this direction's signal advances the candidate; the other path clears a
    /// stale one — the keeper cannot stack a flip the ratio doesn't warrant.
    function _poke(
        Sickle sickle,
        NftPosition calldata position,
        bool wantStaked
    ) private {
        bytes32 key = _key(sickle, position);
        StakeConfig memory cfg = _loadConfig(sickle, position);
        State storage s = stateOf[key];

        bool currentlyStaked = ICLGauge(position.farm.stakingContract)
            .stakedContains(address(sickle), position.tokenId);
        if (wantStaked == currentlyStaked) revert WrongMode();

        (, int24 tickLower, int24 tickUpper) = _positionTicks(position);

        // First poke anchors the fee ring (configure no longer does — the config
        // now lives in NftSettings, set without touching strategy state). A
        // fresh State has prevAt == 0; anchor to "now" and decide on a later
        // poke once a real trailing window has accrued. A rebalance to a new
        // range also re-anchors here: the checkpoints are inside fee growth for
        // the old range and are not comparable across ranges. _anchor sets
        // prev/curr fg + prevAt/currAt to now, records the range, clears any
        // candidate.
        if (
            s.prevAt == 0 || tickLower != s.anchorTickLower
                || tickUpper != s.anchorTickUpper
        ) {
            _anchor(s, cfg, tickLower, tickUpper);
            return;
        }

        // Bound the fee window; re-anchor if the keeper was absent, warm up if
        // the poke came too soon. Either way, decide on a later poke.
        {
            uint256 dt = block.timestamp - s.prevAt;
            if (dt > uint256(cfg.feeWindowTarget) * MAX_WINDOW_MULT) {
                _anchor(s, cfg, tickLower, tickUpper);
                return;
            }
            if (dt < cfg.feeWindowTarget * MIN_WINDOW_NUM / MIN_WINDOW_DEN) {
                _roll(s, cfg, tickLower, tickUpper);
                return;
            }
        }

        // No flip decision while the position is out of range: it earns neither
        // swap fees nor emissions there, so R is not meaningful (both legs ~0)
        // and a flip would act on an artifact (e.g. realized fees read 0 while
        // forward emissions don't). Clear any candidate — a flip needs a
        // continuous in-range signal — keep the ring warm, and decide once the
        // price is back inside [tickLower, tickUpper); the ALM rebalance
        // re-centers an out-of-range position.
        (, int24 tickCurrent,,,,) = ICLPool(cfg.pool).slot0();
        if (tickCurrent < tickLower || tickCurrent >= tickUpper) {
            _updateCandidate(s, false, false);
            _roll(s, cfg, tickLower, tickUpper);
            return;
        }

        (uint256 ratioBps, bool favorUnstake, bool favorStake) =
            _evaluate(cfg, position, currentlyStaked, s);
        emit StakePoked(
            key, ratioBps, favorUnstake, favorStake, currentlyStaked
        );

        // Advance the candidate only for this call's direction. `wantStaked`
        // differs from `currentlyStaked` (checked above), so at most one term
        // is true; the false direction clears a stale candidate.
        _updateCandidate(
            s, !wantStaked && favorUnstake, wantStaked && favorStake
        );
        _roll(s, cfg, tickLower, tickUpper);

        // Flip once the candidate has held the dwell. A candidate set this poke
        // has elapsed 0 < dwell, so it never flips on the poke it first appears.
        if (
            s.hasCandidate
                && block.timestamp - s.candidateSince >= cfg.dwellSeconds
        ) {
            _doFlip(sickle, position, key, ratioBps);
        }
    }

    /// @dev Advance or clear the flip candidate. At most one of `toUnstaked` /
    /// `toStaked` is true (the signal already gated against the current mode).
    function _updateCandidate(
        State storage s,
        bool toUnstaked,
        bool toStaked
    ) private {
        if (toUnstaked || toStaked) {
            if (!s.hasCandidate || s.candidateStaked != toStaked) {
                s.hasCandidate = true;
                s.candidateStaked = toStaked;
                s.candidateSince = uint32(block.timestamp);
            }
        } else {
            s.hasCandidate = false;
            s.candidateSince = 0;
        }
    }

    function _doFlip(
        Sickle sickle,
        NftPosition calldata position,
        bytes32 key,
        uint256 ratioBps
    ) private {
        State storage s = stateOf[key];
        bool toStaked = s.candidateStaked;
        s.hasCandidate = false;
        s.candidateSince = 0;
        _execute(sickle, position, toStaked);
        emit StakeFlipped(key, toStaked, ratioBps);
    }

    /// @notice Current on-chain signal without mutating state (keeper preview).
    function previewRatio(
        Sickle sickle,
        NftPosition calldata position
    )
        external
        view
        returns (uint256 ratioBps, bool favorUnstake, bool favorStake)
    {
        bytes32 key = _key(sickle, position);
        StakeConfig memory cfg = _loadConfig(sickle, position);
        bool currentlyStaked = ICLGauge(position.farm.stakingContract)
            .stakedContains(address(sickle), position.tokenId);
        return _evaluate(cfg, position, currentlyStaked, stateOf[key]);
    }

    /* ---------------------------------------------------------------------- */

    function _evaluate(
        StakeConfig memory cfg,
        NftPosition calldata position,
        bool currentlyStaked,
        State storage s
    )
        private
        view
        returns (uint256 ratioBps, bool favorUnstake, bool favorStake)
    {
        // Built field-by-field in memory (not a literal) to stay off the stack.
        IStakeLib.Inputs memory inp;
        inp.pool = cfg.pool;
        inp.gauge = position.farm.stakingContract;
        inp.twapWindow = cfg.twapWindow;
        inp.currentlyStaked = currentlyStaked;
        inp.unstakedFeeBps = _unstakedFeeBps(cfg.pool);
        inp.thetaUpBps = cfg.thetaUpBps;
        inp.thetaDownBps = cfg.thetaDownBps;
        inp.aeroPriceToken1 = _aeroPriceToken1(cfg);
        {
            (uint128 liquidity, int24 tickLower, int24 tickUpper) =
                _positionTicks(position);
            inp.liquidity = liquidity;
            inp.tickLower = tickLower;
            inp.tickUpper = tickUpper;
            inp.positionValueToken1 =
                _positionValueToken1(cfg, liquidity, tickLower, tickUpper);
        }

        IStakeLib.Snapshot memory snap;
        snap.feeGrowthInside0X128 = s.prevFg0;
        snap.feeGrowthInside1X128 = s.prevFg1;
        snap.timestamp = s.prevAt;

        (ratioBps, favorUnstake, favorStake,,) =
            stakeLib.evaluate(inp, snap);
    }

    function _execute(
        Sickle sickle,
        NftPosition calldata position,
        bool toStaked
    ) private {
        address connector =
            connectorRegistry.connectorOf(position.farm.stakingContract);
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = connector;
        data[0] = toStaked
            ? abi.encodeCall(
                INftFarmConnector.depositExistingNft, (position, bytes(""))
            )
            : abi.encodeCall(
                INftFarmConnector.withdrawNft, (position, bytes(""))
            );
        sickle.multicall(targets, data);
    }

    /// @dev Roll the fee ring: once `curr` is older than the target, it becomes
    /// the new `prev` and a fresh `curr` is taken. Self-gating; called each poke.
    /// `curr` is `feeGrowthInside` for the live range; the range is unchanged
    /// since the anchor (a poke at a new range re-anchors before reaching here).
    function _roll(
        State storage s,
        StakeConfig memory cfg,
        int24 tickLower,
        int24 tickUpper
    ) private {
        if (block.timestamp - s.currAt >= cfg.feeWindowTarget) {
            (uint256 in0, uint256 in1) =
                stakeLib.feeGrowthInside(cfg.pool, tickLower, tickUpper);
            s.prevFg0 = s.currFg0;
            s.prevFg1 = s.currFg1;
            s.prevAt = s.currAt;
            s.currFg0 = in0;
            s.currFg1 = in1;
            s.currAt = uint32(block.timestamp);
        }
    }

    /// @dev Re-anchor both checkpoints to now for `[tickLower, tickUpper]` (the
    /// first poke, a long keeper gap, or a rebalance that changed the range).
    /// Records the range so a later range change re-anchors again; the
    /// checkpoints are inside fee growth and are meaningless across ranges.
    function _anchor(
        State storage s,
        StakeConfig memory cfg,
        int24 tickLower,
        int24 tickUpper
    ) private {
        (uint256 in0, uint256 in1) =
            stakeLib.feeGrowthInside(cfg.pool, tickLower, tickUpper);
        s.anchorTickLower = tickLower;
        s.anchorTickUpper = tickUpper;
        s.prevFg0 = in0;
        s.prevFg1 = in1;
        s.prevAt = uint32(block.timestamp);
        s.currFg0 = in0;
        s.currFg1 = in1;
        s.currAt = uint32(block.timestamp);
        s.hasCandidate = false;
        s.candidateSince = 0;
    }

    function _positionTicks(
        NftPosition calldata position
    )
        private
        view
        returns (uint128 liquidity, int24 tickLower, int24 tickUpper)
    {
        (,,,,, tickLower, tickUpper, liquidity,,,,) =
            position.nft.positions(position.tokenId);
    }

    /// @dev Position value in token1 at the TWAP price. R is invariant to this
    /// (it cancels in fee/emission), but a real value keeps the intermediate
    /// APRs well-resolved in integer math.
    function _positionValueToken1(
        StakeConfig memory cfg,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (uint256) {
        uint160 sqrtP =
            TickMath.getSqrtRatioAtTick(_twapTick(cfg.pool, cfg.twapWindow));
        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
            sqrtP,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
        uint256 amount0InToken1 =
            Math.mulDiv(Math.mulDiv(amount0, sqrtP, Q96), sqrtP, Q96);
        return amount1 + amount0InToken1;
    }

    /// @dev AERO price in token1 (wei per 1e18 AERO), TWAP-derived. AERO==token1
    /// is unit; AERO==token0 uses the vault pool; otherwise the configured
    /// AERO/token1 quote pool.
    function _aeroPriceToken1(
        StakeConfig memory cfg
    ) private view returns (uint256) {
        address t1 = ICLPool(cfg.pool).token1();
        if (cfg.aero == t1) return WAD;
        address quotePool =
            cfg.aero == ICLPool(cfg.pool).token0() ? cfg.pool : cfg.aeroQuotePool;
        uint160 sqrtP =
            TickMath.getSqrtRatioAtTick(_twapTick(quotePool, cfg.twapWindow));
        // (sqrtP/2^96)^2 = price of quote-token0 in quote-token1
        if (cfg.aero == ICLPool(quotePool).token0()) {
            return Math.mulDiv(Math.mulDiv(WAD, sqrtP, Q96), sqrtP, Q96);
        }
        return Math.mulDiv(Math.mulDiv(WAD, Q96, sqrtP), Q96, sqrtP);
    }

    function _unstakedFeeBps(
        address pool
    ) private view returns (uint16) {
        // factory fee is in pips (1e-6); StakeLib wants bps (1e-4)
        uint24 pips =
            ICLPoolFactory(ICLPool(pool).factory()).getUnstakedFee(pool);
        return uint16(uint256(pips) / 100);
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
