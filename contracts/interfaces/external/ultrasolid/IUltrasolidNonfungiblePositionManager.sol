// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IUltrasolidNonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct CollectRewardParams {
        uint256 tokenId;
        address recipient;
        uint128 amountRewardMax;
    }

    function mint(
        MintParams calldata params
    )
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function positions(
        uint256 tokenId
    )
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function positions2(
        uint256 tokenId
    ) external view returns (uint128, address);

    function stake(
        uint256 tokenId,
        uint128 liquidity
    ) external payable;

    function stake(
        uint256 tokenId
    ) external payable;

    function unstake(
        uint256 tokenId
    ) external payable;

    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    function collectReward(
        CollectRewardParams calldata params
    ) external payable returns (uint256 amountReward);
}
