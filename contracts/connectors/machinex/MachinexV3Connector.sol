// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    NftAddLiquidity,
    NftPoolInfo,
    NftPoolKey
} from "contracts/interfaces/INftLiquidityConnector.sol";
import {
    UniswapV3Connector
} from "contracts/connectors/uniswap/UniswapV3Connector.sol";
import {
    IUniswapV3Pool
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {
    SlipstreamAddLiquidityExtraData
} from "contracts/connectors/velodrome/SlipstreamNftConnector.sol";

interface IMachinexClPool {
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

interface IMachinexClFactory {
    function getPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) external view returns (address pool);
}

interface IMachinexNonfungiblePositionManager {
    // Machinex keys pools by tickSpacing (not fee) and, unlike Velodrome
    // Slipstream, its MintParams has no trailing sqrtPriceX96 field.
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
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

    // Machinex omits the leading (nonce, operator) fields that Uniswap's
    // NonfungiblePositionManager returns, and keys by tickSpacing not fee.
    function positions(
        uint256 tokenId
    )
        external
        view
        returns (
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        );
}

contract MachinexV3Connector is UniswapV3Connector {
    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal override {
        SlipstreamAddLiquidityExtraData memory extra = abi.decode(
            addLiquidityParams.extraData, (SlipstreamAddLiquidityExtraData)
        );

        IMachinexNonfungiblePositionManager(address(addLiquidityParams.nft))
            .mint(
            IMachinexNonfungiblePositionManager.MintParams({
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
                deadline: block.timestamp
            })
        );
    }

    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IMachinexClPool(pool).slot0();
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

    function _get_current_tick(
        address pool
    ) internal view override returns (int24 tickCurrent) {
        (, tickCurrent,,,,,) = IMachinexClPool(pool).slot0();
    }

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view override returns (NftPoolKey memory) {
        (address token0, address token1, int24 tickSpacing,,,,,,,) =
            IMachinexNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPoolKey({
            poolAddress: IMachinexClFactory(poolFactory).getPool(
                token0, token1, tickSpacing
            ),
            poolId: bytes32(0) // Uniswap V4 only
         });
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
            IMachinexNonfungiblePositionManager(nftManager).positions(tokenId);
    }

    function _get_fee_params(
        address positionManager,
        uint256 tokenId
    ) internal view override returns (FeeParams memory) {
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
        ) = IMachinexNonfungiblePositionManager(positionManager).positions(
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
}
