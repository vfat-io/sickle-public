// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IUniswapV3Pool } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { NftZapIn, NftZapOut } from "contracts/structs/NftZapStructs.sol";
import { SwapParams } from "contracts/structs/SwapStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";

struct NftPosition {
    Farm farm;
    INonfungiblePositionManager nft;
    uint256 tokenId;
}

struct NftIncrease {
    address[] tokensIn;
    uint256[] amountsIn;
    NftZapIn zap;
    bytes extraData;
}

struct NftDeposit {
    Farm farm;
    INonfungiblePositionManager nft;
    NftIncrease increase;
}

struct NftWithdraw {
    NftZapOut zap;
    address[] tokensOut;
    bytes extraData;
}

struct SimpleNftHarvest {
    address[] rewardTokens;
    uint128 amount0Max;
    uint128 amount1Max;
    bytes extraData;
}

struct NftHarvest {
    SimpleNftHarvest harvest;
    SwapParams[] swaps;
    address[] outputTokens;
    address[] sweepTokens;
}

struct NftCompound {
    SimpleNftHarvest harvest;
    NftZapIn zap;
}

struct NftRebalance {
    IUniswapV3Pool pool;
    NftPosition position;
    NftHarvest harvest;
    NftWithdraw withdraw;
    NftIncrease increase;
}

/// @notice The pool price a keeper-built rebalance is valid for: the
/// inclusive sqrtPriceX96 window in which the add step's `amount0Min` /
/// `amount1Min` can still be met. `boundedRebalanceFor` reverts before
/// the harvest/withdraw/swap when the pool is outside it. Both fields zero
/// declares no window. See ShiftMath._checkRebalancePriceGuardInner.
struct RebalancePriceBounds {
    uint160 minSqrtPriceX96;
    uint160 maxSqrtPriceX96;
}

struct NftMove {
    IUniswapV3Pool pool;
    NftPosition position;
    NftHarvest harvest;
    NftWithdraw withdraw;
    NftDeposit deposit;
}
