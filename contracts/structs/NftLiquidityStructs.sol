// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

struct Pool {
    address token0;
    address token1;
    uint24 fee;
}

struct NftPoolKey {
    address poolAddress;
    bytes32 poolId;
}

struct NftPoolInfo {
    address token0;
    address token1;
    uint24 fee;
    uint24 tickSpacing;
    uint160 sqrtPriceX96;
    int24 tick;
    uint128 liquidity;
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
}

// Maintained for backwards compatibility with NftSettingsRegistry
struct NftPositionInfo {
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
}

struct NftAddLiquidity {
    INonfungiblePositionManager nft;
    uint256 tokenId;
    Pool pool;
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    bytes extraData;
}

struct NftRemoveLiquidity {
    INonfungiblePositionManager nft;
    uint256 tokenId;
    uint128 liquidity;
    uint256 amount0Min; // For decreasing
    uint256 amount1Min;
    uint128 amount0Max; // For collecting
    uint128 amount1Max;
    bytes extraData;
}
