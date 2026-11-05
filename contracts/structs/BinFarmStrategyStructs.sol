// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";
import { SwapParams } from "contracts/structs/SwapStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";

/// @notice Represents a Liquidity Book position across multiple bins
struct BinPosition {
    Farm farm;
    ILBPair lbPair;
}

/// @notice Parameters for adding liquidity to a Liquidity Book pair
struct BinAddLiquidity {
    ILBPair lbPair;
    address tokenX;
    address tokenY;
    uint256 amountX;
    uint256 amountY;
    uint256 amountXMin;
    uint256 amountYMin;
    uint256 activeIdDesired;
    uint256 idSlippage;
    int256[] deltaIds;
    uint256[] distributionX;
    uint256[] distributionY;
}

/// @notice Parameters for removing liquidity from a Liquidity Book pair
struct BinRemoveLiquidity {
    ILBPair lbPair;
    address tokenX;
    address tokenY;
    uint256[] ids;
    uint256[] amounts;
    uint256 amountXMin;
    uint256 amountYMin;
}

/// @notice Zap in parameters for bin-based liquidity
struct BinZapIn {
    SwapParams[] swaps;
    BinAddLiquidity addLiquidityParams;
}

/// @notice Zap out parameters for bin-based liquidity
struct BinZapOut {
    BinRemoveLiquidity removeLiquidityParams;
    SwapParams[] swaps;
}

/// @notice Parameters for increasing a bin position
struct BinIncrease {
    address[] tokensIn;
    uint256[] amountsIn;
    BinZapIn zap;
    bytes extraData;
}

/// @notice Parameters for depositing into a bin farm strategy
struct BinDeposit {
    Farm farm;
    ILBPair lbPair;
    BinIncrease increase;
}

/// @notice Parameters for withdrawing from a bin farm strategy
struct BinWithdraw {
    BinZapOut zap;
    address[] tokensOut;
    bytes extraData;
}

/// @notice Simple harvest parameters without swaps
struct SimpleBinHarvest {
    address[] rewardTokens;
    bytes extraData;
}

/// @notice Parameters for harvesting rewards from a bin farm
struct BinHarvest {
    SimpleBinHarvest harvest;
    SwapParams[] swaps;
    address[] outputTokens;
    address[] sweepTokens;
}

/// @notice Parameters for compounding a bin farm position
struct BinCompound {
    SimpleBinHarvest harvest;
    BinZapIn zap;
    bytes depositExtraData;
}

/// @notice Parameters for rebalancing a bin position
struct BinRebalance {
    BinPosition position;
    uint256[] currentIds; // Current bin IDs to withdraw from
    uint256[] currentAmounts; // Current amounts to withdraw
    BinHarvest harvest;
    BinWithdraw withdraw;
    BinIncrease increase;
}

/// @notice Parameters for moving a bin position to a different farm
struct BinMove {
    BinPosition position;
    uint256[] currentIds;
    uint256[] currentAmounts;
    BinHarvest harvest;
    BinWithdraw withdraw;
    BinDeposit deposit;
}
