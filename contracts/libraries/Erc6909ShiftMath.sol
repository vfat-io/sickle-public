// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ShiftConfig,
    SHIFT_MAGIC
} from "contracts/structs/ShiftConfigStructs.sol";
import {
    NftPositionInfo,
    NftPoolInfo,
    NftAddLiquidity,
    NftRemoveLiquidity
} from "contracts/structs/NftLiquidityStructs.sol";
import {
    NftRebalance,
    RebalancePriceBounds,
    NftCompound,
    NftPosition
} from "contracts/structs/NftFarmStrategyStructs.sol";
import {
    NftSettings,
    RebalanceConfig
} from "contracts/structs/NftSettingsStructs.sol";
import {
    INftSettingsRegistry,
    NftKey
} from "contracts/interfaces/INftSettingsRegistry.sol";
import {
    IErc6909LiquidityConnector
} from "contracts/interfaces/IErc6909LiquidityConnector.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { Sickle } from "contracts/Sickle.sol";
import { IShiftMath } from "contracts/interfaces/libraries/IShiftMath.sol";
import {
    RebalanceRequiresMint,
    RebalanceTargetNftMismatch,
    RebalanceTargetPoolMismatch,
    RebalanceSourceNftMismatch,
    RebalanceSourceTokenIdMismatch,
    RebalancePartialRemoval,
    ShiftNotApplicable,
    ShiftMismatch,
    CompoundRequiresReuse,
    CompoundTargetNftMismatch,
    CompoundPositionNotControlled,
    ShiftTargetUnchanged,
    ShiftTargetTwoCycle,
    RebalanceTargetOutOfRange,
    RebalancePriceOutOfBounds,
    RebalancePriceBoundsMalformed
} from "contracts/libraries/ShiftMath.sol";

/// @notice Rebalance/compound validation for owner-accounted ERC-6909 LP
/// ranges. Geometry is intentionally copied from the baseline ShiftMath;
/// post-mint validation delegates to it. Only checks that need a holder are
/// specialized here.
contract Erc6909ShiftMath is IShiftMath {
    IShiftMath public immutable baseShiftMath;

    constructor(
        IShiftMath baseShiftMath_
    ) {
        baseShiftMath = baseShiftMath_;
    }

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
        return _formulaTicksOutOfRange(cfg, oldPos, poolInfo);
    }

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

    function floorToSpacing(
        int24 tick,
        int24 spacing
    ) public pure override returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q -= 1;
        return q * spacing;
    }

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

        (,, uint128 liquidity) = _positionLiquidity(
            connectorRegistry.connectorOf(address(position.nft)),
            address(position.nft),
            address(sickle),
            position.tokenId
        );
        if (liquidity == 0) {
            revert CompoundPositionNotControlled(address(0));
        }
    }

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
        _checkRebalanceTargetBindings(key, settings, params, connectorRegistry);
        (isShift, expectedLower, expectedUpper) =
            _shiftSetup(key, settings, params, connectorRegistry);
        _checkRebalancePriceGuard(
            key, settings, params, bounds, connectorRegistry
        );
    }

    function postMintRebalanceChecks(
        NftKey memory key,
        NftSettings memory settings,
        uint256 newTokenId,
        bool isShift,
        int24 expectedLower,
        int24 expectedUpper,
        ConnectorRegistry connectorRegistry
    ) external view override {
        baseShiftMath.postMintRebalanceChecks(
            key,
            settings,
            newTokenId,
            isShift,
            expectedLower,
            expectedUpper,
            connectorRegistry
        );
    }

    function _checkRebalanceTargetBindings(
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

        (,, uint128 currentLiquidity) = _positionLiquidity(
            connectorRegistry.connectorOf(address(key.nftManager)),
            address(key.nftManager),
            address(key.sickle),
            key.tokenId
        );
        if (removeLp.liquidity < currentLiquidity) {
            revert RebalancePartialRemoval(removeLp.liquidity, currentLiquidity);
        }
    }

    function _shiftSetup(
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
        if (extraData.length < 32) return (false, 0, 0);

        bytes4 magic;
        assembly {
            magic := mload(add(extraData, 0x20))
        }
        if (magic != SHIFT_MAGIC) return (false, 0, 0);

        ShiftConfig memory cfg = abi.decode(extraData, (ShiftConfig));
        if (!cfg.enabled) return (false, 0, 0);

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
        return (true, expectedLower, expectedUpper);
    }

    /// @dev Stale-quote guard, copied from
    /// ShiftMath._checkRebalancePriceGuardInner (see its doc for the
    /// rationale).
    function _checkRebalancePriceGuard(
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

    function _positionLiquidity(
        address connector,
        address positionManager,
        address holder,
        uint256 rangeId
    )
        private
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        return IErc6909LiquidityConnector(connector)
            .positionLiquidityOf(positionManager, holder, rangeId);
    }

    function _formulaTicksForRebalance(
        ShiftConfig memory cfg,
        RebalanceConfig memory rebalanceConfig,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    ) private pure returns (int24 expectedLower, int24 expectedUpper) {
        int24 tick = poolInfo.tick;
        if (tick >= oldPos.tickUpper) {
            return _formulaTicksUp(cfg, oldPos, poolInfo);
        }
        if (tick < oldPos.tickLower) {
            return _formulaTicksDown(cfg, oldPos, poolInfo);
        }

        int24 lowerTrigger = oldPos.tickLower - rebalanceConfig.bufferTicksBelow;
        int24 upperTrigger = oldPos.tickUpper + rebalanceConfig.bufferTicksAbove;
        bool crossedLowerBand = tick < lowerTrigger;
        bool crossedUpperBand = tick >= upperTrigger;
        if (crossedLowerBand && !crossedUpperBand) {
            return _formulaTicksDown(cfg, oldPos, poolInfo);
        }
        if (crossedUpperBand && !crossedLowerBand) {
            return _formulaTicksUp(cfg, oldPos, poolInfo);
        }
        revert ShiftNotApplicable(tick, oldPos.tickLower, oldPos.tickUpper);
    }

    function _formulaTicksOutOfRange(
        ShiftConfig memory cfg,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    ) private pure returns (int24 expectedLower, int24 expectedUpper) {
        if (poolInfo.tick >= oldPos.tickUpper) {
            return _formulaTicksUp(cfg, oldPos, poolInfo);
        }
        if (poolInfo.tick < oldPos.tickLower) {
            return _formulaTicksDown(cfg, oldPos, poolInfo);
        }
        revert ShiftNotApplicable(
            poolInfo.tick, oldPos.tickLower, oldPos.tickUpper
        );
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
        if (
            expectedLower == oldPos.tickLower
                && expectedUpper == oldPos.tickUpper
        ) {
            revert ShiftTargetUnchanged(expectedLower, expectedUpper);
        }
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
}
