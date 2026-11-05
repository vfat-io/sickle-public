// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { UniswapV3Connector } from
    "contracts/connectors/uniswap/UniswapV3Connector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { IShadowNonfungiblePositionManager } from
    "contracts/interfaces/external/shadow/IShadowNonfungiblePositionManager.sol";
import {
    NftAddLiquidity,
    NftPoolKey
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { NftPoolInfo } from "contracts/structs/NftLiquidityStructs.sol";
import { ICLPoolFactory } from
    "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";
import { ShadowAddLiquidityExtraData } from
    "contracts/connectors/shadow/ShadowV3Connector.sol";
import { IUniswapV3Pool } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { IShadowGaugeV3 } from
    "contracts/interfaces/external/shadow/IShadowGaugeV3.sol";

struct EtherexExtraData {
    bool hasGauge;
    address[] rewardTokens;
}

interface IEtherexClPool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint24 feeProtocol,
            bool unlocked
        );
}

interface IEtherexVoter {
    function gaugeForClPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) external view returns (address);
}

contract EtherexV3Connector is UniswapV3Connector {
    IEtherexVoter public immutable voter;

    constructor(
        IEtherexVoter _voter
    ) {
        voter = IEtherexVoter(_voter);
    }

    function claim(
        NftPosition calldata position,
        address[] memory,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata extraData
    ) external override {
        if (amount0Max != 0 || amount1Max != 0) {
            IShadowNonfungiblePositionManager.CollectParams memory params =
            IShadowNonfungiblePositionManager.CollectParams({
                tokenId: position.tokenId,
                recipient: address(this),
                amount0Max: amount0Max,
                amount1Max: amount1Max
            });
            IShadowNonfungiblePositionManager(address(position.nft)).collect(
                params
            );
        }
        EtherexExtraData memory extra =
            abi.decode(extraData, (EtherexExtraData));
        if (extra.hasGauge) {
            IShadowNonfungiblePositionManager(address(position.nft)).getReward(
                position.tokenId, extra.rewardTokens
            );
        }
    }

    function positionLiquidity(
        address nftManager,
        uint256 tokenId
    )
        public
        view
        override
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        (,,, tickLower, tickUpper, liquidity,,,,) =
            IShadowNonfungiblePositionManager(nftManager).positions(tokenId);
    }

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view override returns (NftPoolKey memory) {
        (address token0, address token1, int24 tickSpacing,,,,,,,) =
            IShadowNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPoolKey({
            poolAddress: ICLPoolFactory(poolFactory).getPool(
                token0, token1, tickSpacing
            ),
            poolId: bytes32(0) // Uniswap V4 only
         });
    }

    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal override {
        ShadowAddLiquidityExtraData memory extra = abi.decode(
            addLiquidityParams.extraData, (ShadowAddLiquidityExtraData)
        );

        IShadowNonfungiblePositionManager.MintParams memory params =
        IShadowNonfungiblePositionManager.MintParams({
            token0: addLiquidityParams.pool.token0,
            token1: addLiquidityParams.pool.token1,
            tickSpacing: extra.tickSpacing,
            tickLower: addLiquidityParams.tickLower,
            tickUpper: addLiquidityParams.tickUpper,
            amount0Desired: addLiquidityParams.amount0Desired,
            amount1Desired: addLiquidityParams.amount1Desired,
            amount0Min: addLiquidityParams.amount0Min,
            amount1Min: addLiquidityParams.amount1Min,
            recipient: address(this),
            deadline: block.timestamp + 1
        });

        IShadowNonfungiblePositionManager(address(addLiquidityParams.nft)).mint(
            params
        );
    }

    function _get_current_tick(
        address pool
    ) internal view override returns (int24 tickCurrent) {
        (, tickCurrent,,,,,) = IEtherexClPool(pool).slot0();
    }

    function _get_fee_params(
        address positionManager,
        uint256 tokenId
    ) internal view virtual override returns (FeeParams memory) {
        (
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 positionFeeGrowthInside0LastX128,
            uint256 positionFeeGrowthInside1LastX128,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        ) = IShadowNonfungiblePositionManager(positionManager).positions(
            tokenId
        );
        return FeeParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            positionFeeGrowthInside0LastX128: positionFeeGrowthInside0LastX128,
            positionFeeGrowthInside1LastX128: positionFeeGrowthInside1LastX128,
            tokensOwed0: tokensOwed0,
            tokensOwed1: tokensOwed1
        });
    }

    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IEtherexClPool(pool).slot0();
        return NftPoolInfo({
            token0: IUniswapV3Pool(pool).token0(),
            token1: IUniswapV3Pool(pool).token1(),
            fee: IUniswapV3Pool(pool).fee(),
            tickSpacing: uint24(IUniswapV3Pool(pool).tickSpacing()),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: IUniswapV3Pool(pool).liquidity(),
            feeGrowthGlobal0X128: IUniswapV3Pool(pool).feeGrowthGlobal0X128(),
            feeGrowthGlobal1X128: IUniswapV3Pool(pool).feeGrowthGlobal1X128()
        });
    }

    function earned(
        address, // user
        NftPosition calldata position,
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        IShadowNonfungiblePositionManager nft =
            IShadowNonfungiblePositionManager(address(position.nft));
        (address token0, address token1, int24 tickSpacing,,,,,,,) =
            nft.positions(position.tokenId);
        address gauge = voter.gaugeForClPool(token0, token1, tickSpacing);
        if (gauge == address(0)) {
            return new uint256[](rewardTokens.length);
        }
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewards[i] = IShadowGaugeV3(gauge).earned(
                rewardTokens[i], address(position.nft), position.tokenId
            );
        }
        return rewards;
    }
}
