// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC721Enumerable } from
    "@openzeppelin/contracts/interfaces/IERC721Enumerable.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { PositionValue } from
    "contracts/interfaces/external/uniswap/v3/PositionValue.sol";
import { IUniswapV3Pool } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from
    "contracts/interfaces/external/uniswap/IUniswapV3Factory.sol";

import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { INftLiquidityConnector } from
    "contracts/interfaces/INftLiquidityConnector.sol";
import {
    NftPoolInfo,
    NftPoolKey,
    NftPositionInfo
} from "contracts/structs/NftLiquidityStructs.sol";
import {
    NftAddLiquidity,
    NftRemoveLiquidity
} from "contracts/structs/NftLiquidityStructs.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

contract UniswapV3Connector is
    INftLiquidityConnector,
    INftFarmConnector,
    PositionValue
{
    error InvalidParameters();
    error NotSupported();

    function addLiquidity(
        NftAddLiquidity memory addLiquidityParams
    ) external override {
        if (addLiquidityParams.tokenId == 0) {
            _mint(addLiquidityParams);
        } else {
            _increaseLiquidity(addLiquidityParams);
        }
    }

    function removeLiquidity(
        NftRemoveLiquidity memory removeLiquidityParams
    ) external override {
        uint128 currentLiquidity;
        if (removeLiquidityParams.liquidity == type(uint128).max) {
            (,, currentLiquidity) = positionLiquidity(
                address(removeLiquidityParams.nft),
                removeLiquidityParams.tokenId
            );
            removeLiquidityParams.liquidity = currentLiquidity;
        }

        if (removeLiquidityParams.liquidity == 0) {
            revert InvalidParameters();
        }

        _decreaseLiquidity(removeLiquidityParams);

        _collect(
            removeLiquidityParams.nft,
            removeLiquidityParams.tokenId,
            removeLiquidityParams.amount0Max,
            removeLiquidityParams.amount1Max
        );

        (,, currentLiquidity) = positionLiquidity(
            address(removeLiquidityParams.nft), removeLiquidityParams.tokenId
        );
        if (currentLiquidity == 0) {
            removeLiquidityParams.nft.burn(removeLiquidityParams.tokenId);
        }
    }

    function depositExistingNft(
        NftPosition calldata, // position,
        bytes calldata // extraData
    ) external virtual override { }

    function withdrawNft(
        NftPosition calldata, // position,
        bytes calldata // extraData
    ) external virtual override { }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata // extraData
    ) external virtual override {
        if (amount0Max > 0 || amount1Max > 0) {
            _collect(position.nft, position.tokenId, amount0Max, amount1Max);
        }
    }

    function poolInfo(
        address pool,
        bytes32 // poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
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

    function fee(
        address pool,
        uint256 // tokenId
    ) external view virtual override returns (uint24) {
        return IUniswapV3Pool(pool).fee();
    }

    function positionPoolKey(
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) external view virtual override returns (NftPoolKey memory) {
        (,, address token0, address token1, uint24 fee_,,,,,,,) =
            INonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPoolKey({
            poolAddress: IUniswapV3Factory(poolFactory).getPool(
                token0, token1, fee_
            ),
            poolId: bytes32(0) // Uniswap V4 only
         });
    }

    function getTokenId(
        address nft,
        address owner
    ) external view virtual returns (uint256) {
        return IERC721Enumerable(nft).tokenOfOwnerByIndex(
            address(owner), IERC721Enumerable(nft).balanceOf(address(owner)) - 1
        );
    }

    function totalSupply(
        address nftManager
    ) external view virtual override returns (uint256) {
        return INonfungiblePositionManager(nftManager).totalSupply();
    }

    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal virtual {
        addLiquidityParams.nft.mint(
            INonfungiblePositionManager.MintParams({
                token0: addLiquidityParams.pool.token0,
                token1: addLiquidityParams.pool.token1,
                fee: addLiquidityParams.pool.fee,
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

    function _increaseLiquidity(
        NftAddLiquidity memory addLiquidityParams
    ) internal {
        addLiquidityParams.nft.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: addLiquidityParams.tokenId,
                amount0Desired: addLiquidityParams.amount0Desired,
                amount1Desired: addLiquidityParams.amount1Desired,
                amount0Min: addLiquidityParams.amount0Min,
                amount1Min: addLiquidityParams.amount1Min,
                deadline: block.timestamp
            })
        );
    }

    function _decreaseLiquidity(
        NftRemoveLiquidity memory removeLiquidityParams
    ) internal {
        removeLiquidityParams.nft.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: removeLiquidityParams.tokenId,
                liquidity: removeLiquidityParams.liquidity,
                amount0Min: removeLiquidityParams.amount0Min,
                amount1Min: removeLiquidityParams.amount1Min,
                deadline: block.timestamp
            })
        );
    }

    function _collect(
        INonfungiblePositionManager nft,
        uint256 tokenId,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal {
        nft.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: amount0Max,
                amount1Max: amount1Max
            })
        );
    }

    function isStaked(
        address,
        NftPosition calldata
    ) external view virtual override returns (bool) {
        return false; // Uniswap V3 does not support staking
    }

    function earned(
        address, // user
        NftPosition calldata,
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        // Uniswap V3 does not support token incentives
        return new uint256[](rewardTokens.length);
    }

    function earnedFees(
        address nftManager,
        address pool,
        uint256 tokenId
    ) external view virtual override returns (uint256 fees0, uint256 fees1) {
        (fees0, fees1) = fees(nftManager, pool, tokenId);
    }

    function positionLiquidity(
        address nftManager,
        uint256 tokenId
    )
        public
        view
        virtual
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        (,,,,, tickLower, tickUpper, liquidity,,,,) =
            INonfungiblePositionManager(nftManager).positions(tokenId);
    }

    function positionInfo(
        address nftManager,
        uint256 tokenId
    ) external view virtual override returns (NftPositionInfo memory) {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            positionLiquidity(nftManager, tokenId);
        return NftPositionInfo({
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
    }
}
