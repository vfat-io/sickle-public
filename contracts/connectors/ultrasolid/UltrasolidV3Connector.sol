// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    UniswapV3Connector
} from "contracts/connectors/uniswap/UniswapV3Connector.sol";
import {
    IUniswapV3PoolState
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { NftPosition } from "contracts/interfaces/INftFarmConnector.sol";
import {
    IUltrasolidNonfungiblePositionManager
} from "contracts/interfaces/external/ultrasolid/IUltrasolidNonfungiblePositionManager.sol";

struct UltrasolidAddLiquidityExtraData {
    bool stake;
}

contract UltrasolidV3Connector is UniswapV3Connector {
    function claim(
        NftPosition calldata position,
        address[] memory,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata
    ) external override {
        (uint128 stakedAmount,) = IUltrasolidNonfungiblePositionManager(
                address(position.nft)
            ).positions2(position.tokenId);
        if (stakedAmount > 0) {
            IUltrasolidNonfungiblePositionManager.CollectRewardParams memory
                collectRewardParams =
                IUltrasolidNonfungiblePositionManager.CollectRewardParams({
                        tokenId: position.tokenId,
                        recipient: address(this),
                        amountRewardMax: type(uint128).max
                    });
            IUltrasolidNonfungiblePositionManager(address(position.nft))
                .collectReward(collectRewardParams);
        }
        if (amount0Max > 0 || amount1Max > 0) {
            IUltrasolidNonfungiblePositionManager.CollectParams memory params =
                IUltrasolidNonfungiblePositionManager.CollectParams({
                    tokenId: position.tokenId,
                    recipient: address(this),
                    amount0Max: amount0Max,
                    amount1Max: amount1Max
                });
            IUltrasolidNonfungiblePositionManager(address(position.nft))
                .collect(params);
        }
    }

    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external virtual override {
        UltrasolidAddLiquidityExtraData memory extra =
            abi.decode(extraData, (UltrasolidAddLiquidityExtraData));
        if (extra.stake) {
            IUltrasolidNonfungiblePositionManager(address(position.nft))
                .stake(position.tokenId);
        }
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata
    ) external virtual override {
        (uint128 stakedAmount,) = IUltrasolidNonfungiblePositionManager(
                address(position.nft)
            ).positions2(position.tokenId);
        if (stakedAmount > 0) {
            IUltrasolidNonfungiblePositionManager(address(position.nft))
                .unstake(position.tokenId);
        }
    }

    /// @dev Bound to `user`. Staking happens on the position manager itself,
    /// so the NFT never leaves its owner and `ownerOf` is the control record.
    /// Taking no custody does not make this unreachable: settings outlive a
    /// position that leaves the Sickle, and if its new owner restakes,
    /// `ownerOf` matches neither the Sickle nor its owner and callers land
    /// here, where a bare `stakedAmount > 0` would wrongly pass.
    function isStaked(
        address user,
        NftPosition calldata position
    ) external view virtual override returns (bool) {
        (uint128 stakedAmount,) = IUltrasolidNonfungiblePositionManager(
                address(position.nft)
            ).positions2(position.tokenId);
        return stakedAmount > 0
            && position.nft.ownerOf(position.tokenId) == user;
    }

    function _get_fee_growth_outside_tick(
        address pool,
        int24 tick
    )
        internal
        view
        virtual
        override
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        (, bytes memory result) = address(pool)
            .staticcall(abi.encodeCall(IUniswapV3PoolState.ticks, (tick)));
        assembly {
            feeGrowthOutside0X128 := mload(add(result, 96))
            feeGrowthOutside1X128 := mload(add(result, 128))
        }
    }

    function earned(
        address, // user
        NftPosition calldata,
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory earnedRewards) {
        earnedRewards = new uint256[](rewardTokens.length);
    }
}
