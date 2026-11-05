// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    NftAddLiquidity,
    NftPoolKey
} from "contracts/structs/NftLiquidityStructs.sol";
import { IEqualizerNonfungiblePositionManager } from
    "contracts/interfaces/external/equalizer/IEqualizerNonfungiblePositionManager.sol";
import { UniswapV3Connector } from
    "contracts/connectors/uniswap/UniswapV3Connector.sol";
import { ICLPoolFactory } from
    "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";
import { SlipstreamAddLiquidityExtraData } from
    "contracts/connectors/velodrome/SlipstreamNftConnector.sol";

contract EqualizerNftConnector is UniswapV3Connector {
    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal override {
        SlipstreamAddLiquidityExtraData memory extra = abi.decode(
            addLiquidityParams.extraData, (SlipstreamAddLiquidityExtraData)
        );

        IEqualizerNonfungiblePositionManager.MintParams memory params =
        IEqualizerNonfungiblePositionManager.MintParams({
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
        });

        IEqualizerNonfungiblePositionManager(address(addLiquidityParams.nft))
            .mint(params);
    }

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view override returns (NftPoolKey memory) {
        (,, address token0, address token1, int24 tickSpacing,,,,,,,) =
            IEqualizerNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPoolKey({
            poolAddress: ICLPoolFactory(poolFactory).getPool(
                token0, token1, tickSpacing
            ),
            poolId: bytes32(0)
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
            IEqualizerNonfungiblePositionManager(nftManager).positions(tokenId);
    }
}
