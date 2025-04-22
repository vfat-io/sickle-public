// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SwapParams } from "contracts/structs/LiquidityStructs.sol";
import {
    NftAddLiquidity,
    NftRemoveLiquidity
} from "contracts/structs/NftLiquidityStructs.sol";

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

struct NftPositionInfo {
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
}

interface INftLiquidityConnector {
    function addLiquidity(
        NftAddLiquidity memory addLiquidityParams
    ) external payable;

    function removeLiquidity(
        NftRemoveLiquidity memory removeLiquidityParams
    ) external;

    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external payable;

    function feeGrowthOutside(
        address pool,
        bytes32 poolId,
        int24 tick
    )
        external
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128);

    function fee(
        address pool,
        uint256 tokenId // Used by UniswapV4
    ) external view returns (uint24);

    function poolInfo(
        address pool,
        bytes32 poolId
    ) external view returns (NftPoolInfo memory);

    function positionInfo(
        address nftManager,
        uint256 tokenId
    ) external view returns (NftPositionInfo memory);

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view returns (NftPoolKey memory);

    function totalSupply(
        address nftManager
    ) external view returns (uint256);

    function getTokenId(
        address nftManager,
        address owner
    ) external view returns (uint256);
}
