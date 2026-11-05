// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IThenaAlgebraFactory } from
    "contracts/interfaces/external/thena/IThenaAlgebraFactory.sol";
import { IThenaNonfungiblePositionManager } from
    "contracts/interfaces/external/thena/IThenaNonfungiblePositionManager.sol";

import { FenixV3Connector } from
    "contracts/connectors/fenix/FenixV3Connector.sol";
import { NftPoolKey } from "contracts/interfaces/INftLiquidityConnector.sol";
import { NftAddLiquidity } from
    "contracts/connectors/uniswap/UniswapV3Connector.sol";

struct ThenaAddLiquidityExtraData {
    address deployer;
}

contract ThenaV3Connector is FenixV3Connector {
    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal virtual override {
        ThenaAddLiquidityExtraData memory extraData = abi.decode(
            addLiquidityParams.extraData, (ThenaAddLiquidityExtraData)
        );
        IThenaNonfungiblePositionManager.MintParams memory params =
        IThenaNonfungiblePositionManager.MintParams({
            token0: addLiquidityParams.pool.token0,
            token1: addLiquidityParams.pool.token1,
            deployer: extraData.deployer,
            tickLower: addLiquidityParams.tickLower,
            tickUpper: addLiquidityParams.tickUpper,
            amount0Desired: addLiquidityParams.amount0Desired,
            amount1Desired: addLiquidityParams.amount1Desired,
            amount0Min: addLiquidityParams.amount0Min,
            amount1Min: addLiquidityParams.amount1Min,
            recipient: address(this),
            deadline: block.timestamp
        });

        IThenaNonfungiblePositionManager(address(addLiquidityParams.nft)).mint(
            params
        );
    }

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view virtual override returns (NftPoolKey memory) {
        (,, address token0, address token1, address deployer,,,,,,,) =
            IThenaNonfungiblePositionManager(nftManager).positions(tokenId);
        IThenaAlgebraFactory factory = IThenaAlgebraFactory(poolFactory);
        address poolAddress = deployer == address(0)
            ? factory.poolByPair(token0, token1)
            : factory.customPoolByPair(deployer, token0, token1);
        return NftPoolKey({
            poolAddress: poolAddress,
            poolId: bytes32(0) // Uniswap V4 only
         });
    }

    function positionLiquidity(
        address nftManager,
        uint256 tokenId
    )
        public
        view
        virtual
        override
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        (,,,,, tickLower, tickUpper, liquidity,,,,) =
            IThenaNonfungiblePositionManager(nftManager).positions(tokenId);
    }

    function _get_fee_params(
        address positionManager,
        uint256 tokenId
    ) internal view virtual override returns (FeeParams memory) {
        (
            ,
            ,
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
        ) = IThenaNonfungiblePositionManager(positionManager).positions(tokenId);
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
