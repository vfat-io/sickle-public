// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    NftAddLiquidity,
    NftRemoveLiquidity,
    NftPoolKey,
    NftPoolInfo,
    NftPositionInfo
} from "contracts/structs/NftLiquidityStructs.sol";

interface INftLiquidityConnector {
    function addLiquidity(
        NftAddLiquidity memory addLiquidityParams
    ) external;

    function removeLiquidity(
        NftRemoveLiquidity memory removeLiquidityParams
    ) external;

    function fee(
        address pool,
        uint256 tokenId // Used by UniswapV4
    ) external view returns (uint24);

    function totalSupply(
        address nftManager
    ) external view returns (uint256);

    function getTokenId(
        address nftManager,
        address owner
    ) external view returns (uint256);

    function earnedFees(
        address nftManager,
        address pool,
        uint256 tokenId
    ) external view returns (uint256 fees0, uint256 fees1);

    function positionLiquidity(
        address nftManager,
        uint256 tokenId
    )
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity);

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view returns (NftPoolKey memory);

    function poolInfo(
        address pool,
        bytes32 poolId
    ) external view returns (NftPoolInfo memory);

    // Maintained for backwards compatibility with NftSettingsRegistry
    function positionInfo(
        address nftManager,
        uint256 tokenId
    ) external view returns (NftPositionInfo memory);
}
