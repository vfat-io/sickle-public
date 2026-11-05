// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";
import { RewardConfig } from "contracts/structs/PositionSettingsStructs.sol";

/// @notice Automation consent applies to one pair and farm inside a Sickle.
/// The configured bin range is the set of shares the keeper may withdraw.
struct BinKey {
    Sickle sickle;
    ILBPair lbPair;
    address stakingContract;
    uint256 poolIndex;
}

/// @notice Exact geometry for an owner-approved keeper shift. The entry
/// offsets count bins between the active bin and the nearest target edge.
struct BinShiftConfig {
    bool enabled;
    uint24 entryBinsUp;
    uint24 entryBinsDown;
}

struct BinSettings {
    bool autoDeposit;
    bool automateRewards;
    RewardConfig rewardConfig;
    bool autoExit;
    bool autoRebalance;
    uint24 rangeLow;
    uint24 rangeHigh;
    uint24 exitBufferBelow;
    uint24 exitBufferAbove;
    int24 rebalanceBufferBelow;
    int24 rebalanceBufferAbove;
    uint24 cutoffLow;
    uint24 cutoffHigh;
    uint256 maxIdSlippage;
    bytes32 rebalanceShapeHash;
    BinShiftConfig shiftConfig;
}
