// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ShiftConfig } from "contracts/structs/ShiftConfigStructs.sol";
import {
    NftPositionInfo,
    NftPoolInfo
} from "contracts/structs/NftLiquidityStructs.sol";
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
import { Sickle } from "contracts/Sickle.sol";

/// @notice Geometry helpers and rebalance/compound binding checks for
/// NftFarmStrategy. Deployed as a normal helper contract following the
/// repo's existing `*Lib` pattern (SwapLib, NftZapLib, etc.) — not a
/// compiler-linked Solidity library. Called via interface so the strategy
/// stays under EIP-170 by offloading helper bytecode here.
interface IShiftMath {
    function expectedTicks(
        ShiftConfig memory cfg,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    ) external pure returns (int24 expectedLower, int24 expectedUpper);

    function expectedTicksForRebalance(
        ShiftConfig memory cfg,
        RebalanceConfig memory rebalanceConfig,
        NftPositionInfo memory oldPos,
        NftPoolInfo memory poolInfo
    ) external pure returns (int24 expectedLower, int24 expectedUpper);

    function floorToSpacing(
        int24 tick,
        int24 spacing
    ) external pure returns (int24);

    function preMintRebalanceChecks(
        INftSettingsRegistry nftSettingsRegistry,
        NftKey memory key,
        NftRebalance calldata params,
        RebalancePriceBounds memory bounds,
        ConnectorRegistry connectorRegistry
    )
        external
        returns (
            NftSettings memory settings,
            bool isShift,
            int24 expectedLower,
            int24 expectedUpper
        );

    function postMintRebalanceChecks(
        NftKey memory key,
        NftSettings memory settings,
        uint256 newTokenId,
        bool isShift,
        int24 expectedLower,
        int24 expectedUpper,
        ConnectorRegistry connectorRegistry
    ) external view;

    function checkCompoundTargetBindings(
        Sickle sickle,
        NftPosition calldata position,
        NftCompound calldata params,
        ConnectorRegistry connectorRegistry
    ) external view;
}
