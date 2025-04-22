// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC721Enumerable } from
    "@openzeppelin/contracts/interfaces/IERC721Enumerable.sol";

import { Farm, NftPosition } from "contracts/interfaces/INftFarmConnector.sol";
import { SwapParams } from "contracts/interfaces/INftLiquidityConnector.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { IMasterchefV3 } from "contracts/interfaces/external/IMasterchefV3.sol";
import {
    UniswapV3Connector,
    NftPoolInfo
} from "contracts/connectors/UniswapV3Connector.sol";
import { IPancakeV3Pool } from
    "contracts/interfaces/external/pancake/IPancakeV3Pool.sol";

contract MasterchefV3Connector is UniswapV3Connector {
    error Unsupported();

    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external payable override {
        IERC721Enumerable(position.nft).safeTransferFrom(
            address(this), position.farm.stakingContract, position.tokenId
        );
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external payable override {
        IMasterchefV3(position.farm.stakingContract).withdraw(
            position.tokenId, address(this)
        );
    }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata // extraData
    ) external payable override {
        IMasterchefV3(position.farm.stakingContract).harvest(
            position.tokenId, address(this)
        );
        if (amount0Max > 0 || amount1Max > 0) {
            INonfungiblePositionManager.CollectParams memory params =
            INonfungiblePositionManager.CollectParams({
                tokenId: position.tokenId,
                recipient: address(this),
                amount0Max: amount0Max,
                amount1Max: amount1Max
            });
            INonfungiblePositionManager(position.farm.stakingContract).collect(
                params
            );
        }
    }

    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IPancakeV3Pool(pool).slot0();
        return NftPoolInfo({
            token0: IPancakeV3Pool(pool).token0(),
            token1: IPancakeV3Pool(pool).token1(),
            fee: IPancakeV3Pool(pool).fee(),
            tickSpacing: uint24(IPancakeV3Pool(pool).tickSpacing()),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: IPancakeV3Pool(pool).liquidity(),
            feeGrowthGlobal0X128: IPancakeV3Pool(pool).feeGrowthGlobal0X128(),
            feeGrowthGlobal1X128: IPancakeV3Pool(pool).feeGrowthGlobal1X128()
        });
    }

    function swapExactTokensForTokens(
        SwapParams memory
    ) external payable override {
        revert Unsupported();
    }
}
