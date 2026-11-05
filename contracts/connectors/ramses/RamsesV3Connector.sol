// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { NftPosition } from "contracts/interfaces/INftFarmConnector.sol";
import { IRamsesNonfungiblePositionManager } from
    "contracts/interfaces/external/ramses/IRamsesNonfungiblePositionManager.sol";
import { IRamsesV2Pool } from
    "contracts/interfaces/external/ramses/IRamsesV2Pool.sol";
import {
    UniswapV3Connector,
    NftAddLiquidity
} from "contracts/connectors/uniswap/UniswapV3Connector.sol";
import { IVoter } from "contracts/interfaces/external/aerodrome/IVoter.sol";
import { IUniswapV3Factory } from
    "contracts/interfaces/external/uniswap/IUniswapV3Factory.sol";
import { IRamsesV2Gauge } from
    "contracts/interfaces/external/ramses/IRamsesV2Gauge.sol";

struct RamsesV3SwapExtraData {
    address pool;
    bytes path;
}

struct RamsesV3ClaimExtraData {
    bool isPool;
}

contract RamsesV3Connector is UniswapV3Connector {
    function claim(
        NftPosition calldata position,
        address[] memory rewardTokens,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata extraData
    ) external override {
        bool isPool = false;
        if (extraData.length == 32) {
            isPool = abi.decode(extraData, (RamsesV3ClaimExtraData)).isPool;
        }
        if (!isPool) {
            IRamsesNonfungiblePositionManager(address(position.nft)).getReward(
                position.tokenId, rewardTokens
            );
        }
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

    function isStaked(
        address, // user
        NftPosition calldata
    ) external view virtual override returns (bool) {
        return false; // Ramses positions stay in the Sickle while earning
            // rewards
    }

    function earned(
        address, // user
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
        if (address(gauge) == address(0)) {
            return new uint256[](rewardTokens.length);
        }
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewards[i] = gauge.earned(rewardTokens[i], position.tokenId);
        }
        return rewards;
    }

    function _get_fee_growth_outside_tick(
        address pool,
        int24 tick_
    )
        internal
        view
        virtual
        override
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        (,,,, feeGrowthOutside0X128, feeGrowthOutside1X128,,,,) =
            IRamsesV2Pool(pool).ticks(tick_);
    }
}
