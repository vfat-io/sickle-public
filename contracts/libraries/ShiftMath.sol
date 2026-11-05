// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ShiftConfig,
    SHIFT_MAGIC
} from "contracts/structs/ShiftConfigStructs.sol";
import {
    NftPositionInfo,
    NftPoolInfo,
    NftPoolKey,
    NftAddLiquidity,
    NftRemoveLiquidity
} from "contracts/structs/NftLiquidityStructs.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { Sickle } from "contracts/Sickle.sol";
import {
    INftSettingsRegistry,
    NftKey
} from "contracts/interfaces/INftSettingsRegistry.sol";
import {
    NftSettings,
    RebalanceConfig
} from "contracts/structs/NftSettingsStructs.sol";
import {
    NftRebalance,
    RebalancePriceBounds,
    NftCompound,
    NftPosition
} from "contracts/structs/NftFarmStrategyStructs.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IShiftMath } from "contracts/interfaces/libraries/IShiftMath.sol";

// File-scope errors so the test suite + strategy can match them without
// import gymnastics.
error ShiftNotApplicable(
    int24 poolTick, int24 oldTickLower, int24 oldTickUpper
);
error ShiftMismatch(
    int24 oldTickLower,
    int24 oldTickUpper,
    int24 newTickLower,
    int24 newTickUpper,
    int24 expectedNewTickLower,
    int24 expectedNewTickUpper,
    int24 poolTick
);
error RebalanceRequiresMint(uint256 actualTokenId);
error RebalanceTargetNftMismatch(address expected, address actual);
error RebalanceTargetPoolMismatch(address expected, address actual);
error RebalanceSourceNftMismatch(address expected, address actual);
error RebalanceSourceTokenIdMismatch(uint256 expected, uint256 actual);
error RebalancePartialRemoval(uint128 requested, uint128 current);
error RebalanceMintedToWrongPool(
    address expectedPool,
    address actualPool,
    bytes32 expectedPoolId,
    bytes32 actualPoolId
);
error CompoundRequiresReuse(uint256 expectedTokenId, uint256 actualTokenId);
error CompoundTargetNftMismatch(address expected, address actual);
error ShiftTargetUnchanged(int24 tickLower, int24 tickUpper);
error ShiftTargetTwoCycle(
    int24 currentTickLower,
    int24 currentTickUpper,
    int24 targetTickLower,
    int24 targetTickUpper
);
error CompoundPositionNotControlled(address nftOwner);
// Stale-quote guard (see ShiftMath._checkRebalancePriceGuardInner).
error RebalanceTargetOutOfRange(
    int24 poolTick, int24 tickLower, int24 tickUpper
);
error RebalancePriceOutOfBounds(
    uint160 sqrtPriceX96, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96
);
error RebalancePriceBoundsMalformed(
    uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96
);

/// @notice Geometry helpers and rebalance/compound binding checks for
/// NftFarmStrategy. Deployed as a normal helper contract (following the
/// repo's existing `*Lib` pattern: SwapLib, NftZapLib, etc.) and called
/// via IShiftMath, so the strategy stays under EIP-170 by offloading
/// helper bytecode here.
contract ShiftMath is IShiftMath {
    /// @notice Derive out-of-range shift geometry from the user's config and
    /// pool/position state. This geometry-only helper does not evaluate
    /// rebalance triggers or repeat-cycle guards; use
    /// expectedTicksForRebalance for keeper execution parity.
    function expectedTicks(
        ShiftConfig memory cfg,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    )
        external
        pure
        override
        returns (int24 expectedLower, int24 expectedUpper)
    {
        return _formulaTicks(cfg, oldPos, poolInfo);
    }

    /// @notice Derive the target tick range for keeper-driven rebalanceFor,
    /// including negative-buffer triggers that fire while the tick is still
    /// inside the old position's range.
    function expectedTicksForRebalance(
        ShiftConfig memory cfg,
        RebalanceConfig memory rebalanceConfig,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    )
        external
        pure
        override
        returns (int24 expectedLower, int24 expectedUpper)
    {
        (
            expectedLower, expectedUpper
        ) = _formulaTicksForRebalance(cfg, rebalanceConfig, oldPos, poolInfo);
        _checkNoRepeatCycle(cfg, oldPos, poolInfo, expectedLower, expectedUpper);
    }

    /// @notice Floor a tick to the nearest spacing-aligned tick toward
    /// negative infinity.
    function floorToSpacing(
        int24 tick,
        int24 spacing
    ) public pure override returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) {
            q -= 1;
        }
        return q * spacing;
    }

    /// @notice Pre-call compoundFor target bindings. Reuse-only: the keeper
    /// must grow the configured position.
    function checkCompoundTargetBindings(
        Sickle sickle,
        NftPosition calldata position,
        NftCompound calldata params,
        ConnectorRegistry connectorRegistry
    ) external view override {
        NftAddLiquidity calldata addLp = params.zap.addLiquidityParams;
        if (address(addLp.nft) != address(position.nft)) {
            revert CompoundTargetNftMismatch(
                address(position.nft), address(addLp.nft)
            );
        }
        if (addLp.tokenId != position.tokenId) {
            revert CompoundRequiresReuse(position.tokenId, addLp.tokenId);
        }
        // The settings are keyed by (sickle, manager, tokenId) and survive the
        // NFT leaving custody -- simpleWithdraw/simpleExit transfer it out
        // without clearing them. Adding liquidity to an existing position is
        // permissionless, so an in-place compound would happily zap the
        // Sickle's rewards into a position its new owner controls. Establish
        // current control, not just calldata identity.
        address nftOwner = position.nft.ownerOf(position.tokenId);
        if (nftOwner != address(sickle) && nftOwner != sickle.owner()) {
            // Custody-taking farms hold the NFT themselves, so ownerOf
            // reports the staking contract and cannot answer; ask the farm.
            // See MultiFarmStrategy._checkDepositTarget for what each
            // connector's answer is worth.
            address farmConnector =
                connectorRegistry.connectorOf(position.farm.stakingContract);
            bool staked = INftFarmConnector(farmConnector)
                .isStaked(address(sickle), position);

            if (!staked) {
                revert CompoundPositionNotControlled(nftOwner);
            }
        }
    }

    function _formulaTicks(
        ShiftConfig memory cfg,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    ) private pure returns (int24 expectedLower, int24 expectedUpper) {
        return _formulaTicksOutOfRange(cfg, oldPos, poolInfo);
    }

    function _formulaTicksForRebalance(
        ShiftConfig memory cfg,
        RebalanceConfig memory rebalanceConfig,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    ) internal pure returns (int24 expectedLower, int24 expectedUpper) {
        bool applicable;
        (applicable, expectedLower, expectedUpper) = _tryFormulaTicksForRebalance(
            cfg, rebalanceConfig, oldPos, poolInfo
        );
        if (!applicable) {
            revert ShiftNotApplicable(
                poolInfo.tick, oldPos.tickLower, oldPos.tickUpper
            );
        }
    }

    function _tryFormulaTicksForRebalance(
        ShiftConfig memory cfg,
        RebalanceConfig memory rebalanceConfig,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    )
        private
        pure
        returns (bool applicable, int24 expectedLower, int24 expectedUpper)
    {
        int24 tick = poolInfo.tick;

        if (tick >= oldPos.tickUpper) {
            (expectedLower, expectedUpper) =
                _formulaTicksUp(cfg, oldPos, poolInfo);
            return (true, expectedLower, expectedUpper);
        } else if (tick < oldPos.tickLower) {
            (expectedLower, expectedUpper) =
                _formulaTicksDown(cfg, oldPos, poolInfo);
            return (true, expectedLower, expectedUpper);
        }

        int24 lowerTrigger = oldPos.tickLower - rebalanceConfig.bufferTicksBelow;
        int24 upperTrigger = oldPos.tickUpper + rebalanceConfig.bufferTicksAbove;
        bool crossedLowerBand = tick < lowerTrigger;
        bool crossedUpperBand = tick >= upperTrigger;

        if (crossedLowerBand && !crossedUpperBand) {
            (expectedLower, expectedUpper) =
                _formulaTicksDown(cfg, oldPos, poolInfo);
            return (true, expectedLower, expectedUpper);
        } else if (crossedUpperBand && !crossedLowerBand) {
            (expectedLower, expectedUpper) =
                _formulaTicksUp(cfg, oldPos, poolInfo);
            return (true, expectedLower, expectedUpper);
        }

        return (false, 0, 0);
    }

    function _formulaTicksOutOfRange(
        ShiftConfig memory cfg,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    ) private pure returns (int24 expectedLower, int24 expectedUpper) {
        int24 tick = poolInfo.tick;

        if (tick >= oldPos.tickUpper) {
            return _formulaTicksUp(cfg, oldPos, poolInfo);
        } else if (tick < oldPos.tickLower) {
            return _formulaTicksDown(cfg, oldPos, poolInfo);
        }

        revert ShiftNotApplicable(tick, oldPos.tickLower, oldPos.tickUpper);
    }

    function _formulaTicksUp(
        ShiftConfig memory cfg,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    ) private pure returns (int24 expectedLower, int24 expectedUpper) {
        int24 spacing = int24(poolInfo.tickSpacing);
        int24 width = oldPos.tickUpper - oldPos.tickLower;
        int24 tickFloor = floorToSpacing(poolInfo.tick, spacing);
        expectedLower = tickFloor - cfg.entryTickSpacesUp * spacing;
        expectedUpper = expectedLower + width;
    }

    function _formulaTicksDown(
        ShiftConfig memory cfg,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    ) private pure returns (int24 expectedLower, int24 expectedUpper) {
        int24 spacing = int24(poolInfo.tickSpacing);
        int24 width = oldPos.tickUpper - oldPos.tickLower;
        int24 tickFloor = floorToSpacing(poolInfo.tick, spacing);
        expectedUpper = tickFloor + (cfg.entryTickSpacesDown + 1) * spacing;
        expectedLower = expectedUpper - width;
    }

    function _checkNoRepeatCycle(
        ShiftConfig memory cfg,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo,
        int24 expectedLower,
        int24 expectedUpper
    ) private pure {
        // Reject a fixed point: a target identical to the position being
        // replaced. This stops an immediately repeatable same-range
        // rebalance.
        if (
            expectedLower == oldPos.tickLower
                && expectedUpper == oldPos.tickUpper
        ) {
            revert ShiftTargetUnchanged(expectedLower, expectedUpper);
        }

        // Within one tick-space the formulas can produce only two distinct
        // ranges: the up target U and the down target D. Raw-tick trigger
        // thresholds are not spacing-aligned, so projecting only at the
        // current tick is insufficient: a one-tick price move can make U
        // select D and D select U without changing either target. Reject any
        // direct transition between those two formula ranges. A position
        // that is not already U or D can still make its initial shift.
        (int24 upLower, int24 upUpper) = _formulaTicksUp(cfg, oldPos, poolInfo);
        (int24 downLower, int24 downUpper) =
            _formulaTicksDown(cfg, oldPos, poolInfo);

        bool distinctTargets = upLower != downLower || upUpper != downUpper;
        bool upToDown = oldPos.tickLower == upLower
            && oldPos.tickUpper == upUpper && expectedLower == downLower
            && expectedUpper == downUpper;
        bool downToUp = oldPos.tickLower == downLower
            && oldPos.tickUpper == downUpper && expectedLower == upLower
            && expectedUpper == upUpper;
        if (distinctTargets && (upToDown || downToUp)) {
            revert ShiftTargetTwoCycle(
                oldPos.tickLower, oldPos.tickUpper, expectedLower, expectedUpper
            );
        }
    }

    /// @notice Pre-mint rebalanceFor entry point. Runs validateRebalanceFor,
    /// loads settings, enforces the unconditional target bindings, runs the
    /// shift-mode setup, then the stale-quote price guard. Single library
    /// call from the strategy keeps NftFarmStrategy under EIP-170.
    function preMintRebalanceChecks(
        INftSettingsRegistry nftSettingsRegistry,
        NftKey memory key,
        NftRebalance calldata params,
        RebalancePriceBounds memory bounds,
        ConnectorRegistry connectorRegistry
    )
        external
        override
        returns (
            NftSettings memory settings,
            bool isShift,
            int24 expectedLower,
            int24 expectedUpper
        )
    {
        nftSettingsRegistry.validateRebalanceFor(key);
        settings = nftSettingsRegistry.getNftSettings(key);
        _checkRebalanceTargetBindingsInner(
            key, settings, params, connectorRegistry
        );
        (isShift, expectedLower, expectedUpper) =
            _shiftSetupInner(key, settings, params, connectorRegistry);
        _checkRebalancePriceGuardInner(
            key, settings, params, bounds, connectorRegistry
        );
    }

    /// @notice Post-mint rebalanceFor entry point. Runs the unconditional
    /// pool-identity check and, when shift is active, the formula tick
    /// equality check.
    function postMintRebalanceChecks(
        NftKey memory key,
        NftSettings memory settings,
        uint256 newTokenId,
        bool isShift,
        int24 expectedLower,
        int24 expectedUpper,
        ConnectorRegistry connectorRegistry
    ) external view override {
        INftLiquidityConnector connector = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(key.nftManager))
        );
        _verifyMintPoolIdentityInner(key, settings, newTokenId, connector);
        if (isShift) {
            _verifyShiftTicksInner(
                key, newTokenId, expectedLower, expectedUpper, connector
            );
        }
    }

    // ----- inner implementations (private; called only from the two
    // external entry points above) -----

    function _checkRebalanceTargetBindingsInner(
        NftKey memory key,
        NftSettings memory settings,
        NftRebalance calldata params,
        ConnectorRegistry connectorRegistry
    ) private view {
        NftAddLiquidity calldata addLp = params.increase.zap.addLiquidityParams;
        if (addLp.tokenId != 0) {
            revert RebalanceRequiresMint(addLp.tokenId);
        }
        if (address(addLp.nft) != address(key.nftManager)) {
            revert RebalanceTargetNftMismatch(
                address(key.nftManager), address(addLp.nft)
            );
        }
        if (address(params.pool) != address(settings.pool)) {
            revert RebalanceTargetPoolMismatch(
                address(settings.pool), address(params.pool)
            );
        }
        // The settings check above authorizes `key`, but the withdrawal
        // parameters are supplied independently and `NftZapLib.zapOut()`
        // selects its connector and position straight from them. Without this
        // binding, consent to rebalance position A also permits removing
        // liquidity from any other NFT the Sickle holds.
        NftRemoveLiquidity calldata removeLp =
        params.withdraw.zap.removeLiquidityParams;
        if (address(removeLp.nft) != address(key.nftManager)) {
            revert RebalanceSourceNftMismatch(
                address(key.nftManager), address(removeLp.nft)
            );
        }
        if (removeLp.tokenId != key.tokenId) {
            revert RebalanceSourceTokenIdMismatch(key.tokenId, removeLp.tokenId);
        }
        // A rebalance must fully drain the old position: `_rebalance()` mints
        // a replacement and migrates every core and module setting onto it, so
        // a partial removal would leave the original NFT live, unstaked and
        // policy-less while automation followed a smaller replacement.
        //
        // Expressed against the position's live liquidity rather than as a
        // supply-unchanged check. Both are the same "net to zero" intent, but
        // `totalSupply()` cannot carry it across connectors: V3 reports the
        // live IERC721Enumerable count (burn -1, mint +1 = 0), whereas the
        // V4-family connectors report `nextTokenId() - 1`, a monotonic mint
        // counter that never decrements — so a correct V4 rebalance moves it
        // +1. That mismatch is why the check was dropped from rebalance in
        // d3ddffe2, and it still rules the modifier out here.
        //
        // Comparing against current liquidity accepts both encodings the
        // keeper already uses — the `type(uint128).max` sentinel and the
        // exact
        // current liquidity — while rejecting anything that leaves a
        // remainder. It also closes the exact-liquidity window: this reads
        // liquidity after the pre-rebalance callbacks have run, so a callback
        // that tops the old position up makes the keeper's pre-computed
        // amount fall short and reverts instead of orphaning the surplus.
        (,, uint128 currentLiquidity) = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(key.nftManager))
        ).positionLiquidity(address(key.nftManager), key.tokenId);

        if (removeLp.liquidity < currentLiquidity) {
            revert RebalancePartialRemoval(removeLp.liquidity, currentLiquidity);
        }
    }

    function _shiftSetupInner(
        NftKey memory key,
        NftSettings memory settings,
        NftRebalance calldata params,
        ConnectorRegistry connectorRegistry
    )
        private
        view
        returns (bool isShift, int24 expectedLower, int24 expectedUpper)
    {
        bytes memory extraData = settings.extraData;
        if (extraData.length < 32) {
            return (false, 0, 0);
        }
        bytes4 magic;
        assembly {
            magic := mload(add(extraData, 0x20))
        }
        if (magic != SHIFT_MAGIC) {
            return (false, 0, 0);
        }
        ShiftConfig memory cfg = abi.decode(extraData, (ShiftConfig));
        if (!cfg.enabled) {
            return (false, 0, 0);
        }

        INftLiquidityConnector connector = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(key.nftManager))
        );
        NftPositionInfo memory oldPos =
            connector.positionInfo(address(key.nftManager), key.tokenId);
        NftPoolInfo memory poolInfo =
            connector.poolInfo(address(settings.pool), settings.poolId);

        (expectedLower, expectedUpper) = _formulaTicksForRebalance(
            cfg, settings.rebalanceConfig, oldPos, poolInfo
        );
        _checkNoRepeatCycle(cfg, oldPos, poolInfo, expectedLower, expectedUpper);

        int24 newLower = params.increase.zap.addLiquidityParams.tickLower;
        int24 newUpper = params.increase.zap.addLiquidityParams.tickUpper;
        if (newLower != expectedLower || newUpper != expectedUpper) {
            revert ShiftMismatch(
                oldPos.tickLower,
                oldPos.tickUpper,
                newLower,
                newUpper,
                expectedLower,
                expectedUpper,
                poolInfo.tick
            );
        }

        isShift = true;
    }

    /// @dev Stale-quote guard. Keeper calldata for a rebalance is built for
    /// one pool price: the add step's `amount0Min`/`amount1Min` encode the
    /// token ratio at that price, and on the narrow ranges automation
    /// targets (1-14 ticks) they stay satisfiable inside a window of well
    /// under one tick. Any trade landing between quote and inclusion turns
    /// the mint into a `Price slippage check` revert, after the harvest,
    /// withdraw and aggregator swap have already burnt ~1.5M gas that no
    /// one is reimbursed for. This check reads only the pool price; a
    /// rebalance it rejects costs ~250k gas all in.
    ///
    /// Two independent tests, both exact with respect to the minimums the
    /// caller itself supplied:
    ///
    /// 1. Range test, always on. With the pool tick at or above the target
    ///    range the mint takes no token0, below it no token1; a non-zero
    ///    minimum on that side cannot be met. A zero minimum keeps
    ///    single-sided targets allowed. This enforces the minimums as the
    ///    caller declared them, uniformly across connectors: V3-style
    ///    position managers check the same minimums inside mint, whereas
    ///    the V4 / Pancake Infinity / Fables connectors size the mint by a
    ///    declared liquidity and never read them. There a target the tick
    ///    has left would otherwise mint single-sided with the surplus swept
    ///    to the owner, or revert on the amount maximum after the full
    ///    rebalance body. Rejecting up front is the intended behaviour; a
    ///    caller that wants a single-sided mint declares a zero minimum.
    /// 2. Price window, caller opt-in through `boundedRebalanceFor`: the
    ///    inclusive sqrtPriceX96 window the calldata was built for. Both
    ///    bounds zero declares none (`rebalanceFor`). Sub-tick resolution
    ///    matters: 1 in 6 of the observed failures moved the price without
    ///    changing the tick.
    ///
    /// Runs last so every existing authorization, binding and shift error
    /// keeps its precedence; the pool reads it repeats are warm by now.
    function _checkRebalancePriceGuardInner(
        NftKey memory key,
        NftSettings memory settings,
        NftRebalance calldata params,
        RebalancePriceBounds memory bounds,
        ConnectorRegistry connectorRegistry
    ) private view {
        NftAddLiquidity calldata addLp = params.increase.zap.addLiquidityParams;
        NftPoolInfo memory poolInfo = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(key.nftManager))
        ).poolInfo(address(settings.pool), settings.poolId);

        if (
            (poolInfo.tick >= addLp.tickUpper && addLp.amount0Min > 0)
                || (poolInfo.tick < addLp.tickLower && addLp.amount1Min > 0)
        ) {
            revert RebalanceTargetOutOfRange(
                poolInfo.tick, addLp.tickLower, addLp.tickUpper
            );
        }

        if (bounds.minSqrtPriceX96 == 0 && bounds.maxSqrtPriceX96 == 0) {
            return;
        }
        if (bounds.minSqrtPriceX96 > bounds.maxSqrtPriceX96) {
            revert RebalancePriceBoundsMalformed(
                bounds.minSqrtPriceX96, bounds.maxSqrtPriceX96
            );
        }
        if (
            poolInfo.sqrtPriceX96 < bounds.minSqrtPriceX96
                || poolInfo.sqrtPriceX96 > bounds.maxSqrtPriceX96
        ) {
            revert RebalancePriceOutOfBounds(
                poolInfo.sqrtPriceX96,
                bounds.minSqrtPriceX96,
                bounds.maxSqrtPriceX96
            );
        }
    }

    function _verifyMintPoolIdentityInner(
        NftKey memory key,
        NftSettings memory settings,
        uint256 newTokenId,
        INftLiquidityConnector connector
    ) private view {
        // Derive the pool factory from the configured pool, not the NFT
        // manager: Ramses-fork managers (Shadow, Ramses, Pharaoh, Etherex)
        // either lack factory() or return an unrelated address, whereas the
        // pool's factory() is the one whose getPool() reproduces the pool.
        // This matches how the lens/tests resolve the factory.
        address poolFactory = settings.poolId == bytes32(0)
            ? settings.pool.factory()
            : address(0);
        NftPoolKey memory mintKey = connector.positionPoolKey(
            poolFactory, address(key.nftManager), newTokenId
        );
        bool mismatch = settings.poolId == bytes32(0)
            ? mintKey.poolAddress != address(settings.pool)
            : mintKey.poolId != settings.poolId;
        if (mismatch) {
            revert RebalanceMintedToWrongPool(
                address(settings.pool),
                mintKey.poolAddress,
                settings.poolId,
                mintKey.poolId
            );
        }
    }

    function _verifyShiftTicksInner(
        NftKey memory key,
        uint256 newTokenId,
        int24 expectedLower,
        int24 expectedUpper,
        INftLiquidityConnector connector
    ) private view {
        NftPositionInfo memory newPos =
            connector.positionInfo(address(key.nftManager), newTokenId);
        if (
            newPos.tickLower != expectedLower
                || newPos.tickUpper != expectedUpper
        ) {
            revert ShiftMismatch(
                0,
                0,
                newPos.tickLower,
                newPos.tickUpper,
                expectedLower,
                expectedUpper,
                0
            );
        }
    }
}
