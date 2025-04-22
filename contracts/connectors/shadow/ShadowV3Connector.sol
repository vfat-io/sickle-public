// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICLPoolFactory } from
    "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { IShadowNonfungiblePositionManager } from
    "contracts/interfaces/external/shadow/IShadowNonfungiblePositionManager.sol";
import { UniswapV3Connector } from
    "contracts/connectors/velodrome/SlipstreamNftConnector.sol";
import {
    NftAddLiquidity,
    NftRemoveLiquidity,
    NftPositionInfo,
    NftPoolKey
} from "contracts/interfaces/INftLiquidityConnector.sol";
import {
    INftFarmConnector,
    Farm,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import { IShadowGaugeV3 } from
    "contracts/interfaces/external/shadow/IShadowGaugeV3.sol";
import {
    ShadowRewardBehavior,
    ShadowV3GaugeClaim
} from "contracts/connectors/shadow/ShadowGaugeClaim.sol";

struct ShadowAddLiquidityExtraData {
    int24 tickSpacing;
}

struct ShadowClaimExtraData {
    address gauge;
    address[] claimTokens;
    ShadowRewardBehavior behavior;
}

contract ShadowV3Connector is UniswapV3Connector, ShadowV3GaugeClaim {
    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens not used here
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata extraData
    ) external payable override {
        if (amount0Max != 0 || amount1Max != 0) {
            // Claim fees if applicable
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

        if (extraData.length > 0) {
            // Claim from previous gauge if applicable
            ShadowClaimExtraData memory extra =
                abi.decode(extraData, (ShadowClaimExtraData));

            _claimGaugeRewards(
                extra.gauge, position.tokenId, extra.claimTokens, extra.behavior
            );
        }
    }

    function positionInfo(
        address nftManager,
        uint256 tokenId
    ) public view override returns (NftPositionInfo memory) {
        (,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            IShadowNonfungiblePositionManager(nftManager).positions(tokenId);
        return NftPositionInfo({
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
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
}
