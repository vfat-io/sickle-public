// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import {
    NftPosition,
    NftRebalance,
    RebalancePriceBounds,
    NftHarvest,
    NftWithdraw,
    NftCompound,
    NftIncrease
} from "contracts/structs/NftFarmStrategyStructs.sol";

interface INftAutomation {
    /// @dev The caller must pass the live vault position. Implementations only
    /// validate that the position tokenId and add-liquidity target match.
    function depositFor(
        Sickle sickle,
        NftPosition calldata position,
        NftIncrease calldata increaseParams,
        address[] calldata sweepTokens
    ) external;

    function rebalanceFor(
        Sickle sickle,
        NftRebalance calldata rebalance,
        address[] calldata sweepTokens
    ) external;

    /// @notice `rebalanceFor` for calldata that is only valid inside a pool
    /// price window. Reverts before any position work when the pool price
    /// is outside `bounds`; a zero `bounds` is `rebalanceFor`.
    function boundedRebalanceFor(
        Sickle sickle,
        NftRebalance calldata rebalance,
        address[] calldata sweepTokens,
        RebalancePriceBounds calldata bounds
    ) external;

    function harvestFor(
        Sickle sickle,
        NftPosition calldata position,
        NftHarvest calldata params
    ) external;

    function compoundFor(
        Sickle sickle,
        NftPosition calldata position,
        NftCompound calldata params,
        bool inPlace,
        address[] memory sweepTokens
    ) external;

    function exitFor(
        Sickle sickle,
        NftPosition calldata position,
        NftHarvest calldata harvestParams,
        NftWithdraw calldata withdrawParams,
        address[] memory sweepTokens
    ) external;
}
