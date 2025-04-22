// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapParams } from "contracts/structs/LiquidityStructs.sol";
import {
    INftFarmConnector,
    Farm,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import
    "contracts/interfaces/external/ramses/IRamsesNonfungiblePositionManager.sol";
import { IRamsesV2Pool } from
    "contracts/interfaces/external/ramses/IRamsesV2Pool.sol";
import { ISwapRouter } from
    "contracts/interfaces/external/uniswap/ISwapRouter.sol";
import {
    UniswapV3Connector,
    NftAddLiquidity
} from "contracts/connectors/UniswapV3Connector.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { IVoter } from "contracts/interfaces/external/aerodrome/IVoter.sol";
import { IUniswapV3Factory } from
    "contracts/interfaces/external/uniswap/IUniswapV3Factory.sol";
import { IRamsesV2Gauge } from
    "contracts/interfaces/external/ramses/IRamsesV2Gauge.sol";

struct RamsesV3SwapExtraData {
    address pool;
    bytes path;
}

contract RamsesV3Connector is UniswapV3Connector {
    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external payable override {
        RamsesV3SwapExtraData memory extraData =
            abi.decode(swap.extraData, (RamsesV3SwapExtraData));

        IERC20(swap.tokenIn).approve(extraData.pool, swap.amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
            path: extraData.path,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: swap.amountIn,
            amountOutMinimum: swap.minAmountOut
        });

        ISwapRouter(swap.router).exactInput(params);
    }

    function claim(
        NftPosition calldata position,
        address[] memory rewardTokens,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata // extraData
    ) external payable override {
        IRamsesNonfungiblePositionManager(address(position.nft)).getReward(
            position.tokenId, rewardTokens
        );
        if (amount0Max > 0 || amount1Max > 0) {
            IRamsesNonfungiblePositionManager.CollectParams memory params =
            IRamsesNonfungiblePositionManager.CollectParams({
                tokenId: position.tokenId,
                recipient: address(this),
                amount0Max: amount0Max,
                amount1Max: amount1Max
            });
            IRamsesNonfungiblePositionManager(address(position.nft)).collect(
                params
            );
        }
    }

    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal virtual override {
        IRamsesNonfungiblePositionManager.MintParams memory params =
        IRamsesNonfungiblePositionManager.MintParams({
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
            deadline: block.timestamp,
            veRamTokenId: 0
        });

        IRamsesNonfungiblePositionManager(address(addLiquidityParams.nft)).mint(
            params
        );
    }

    function feeGrowthOutside(
        address pool,
        bytes32, // poolId
        int24 tick_
    )
        external
        view
        virtual
        override
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        (,,,, feeGrowthOutside0X128, feeGrowthOutside1X128,,,,) =
            IRamsesV2Pool(pool).ticks(tick_);
    }

    function isStaked(
        address, // user
        NftPosition calldata
    ) external view virtual override returns (bool) {
        return true; // Ramses positions are staked by default
    }

    function earned(
        NftPosition calldata position,
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        IRamsesNonfungiblePositionManager nft =
            IRamsesNonfungiblePositionManager(address(position.nft));
        IVoter voter = IVoter(nft.voter());
        (,, address token0, address token1, uint24 fee_,,,,,,,) =
            nft.positions(position.tokenId);
        IUniswapV3Factory factory = IUniswapV3Factory(nft.factory());
        address pool = factory.getPool(token0, token1, fee_);
        IRamsesV2Gauge gauge = IRamsesV2Gauge(voter.gauges(pool));
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewards[i] = gauge.earned(rewardTokens[i], position.tokenId);
        }
        return rewards;
    }
}
