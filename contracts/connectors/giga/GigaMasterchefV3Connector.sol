// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IERC721Enumerable
} from "@openzeppelin/contracts/interfaces/IERC721Enumerable.sol";
import {
    PancakeV3Connector
} from "contracts/connectors/pancake/PancakeV3Connector.sol";
import { NftPosition } from "contracts/interfaces/INftFarmConnector.sol";
import { IMasterchefV3 } from "contracts/interfaces/external/IMasterchefV3.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {
    IPancakeV3Pool
} from "contracts/interfaces/external/pancake/IPancakeV3Pool.sol";
import {
    IPancakeV3LmPool
} from "contracts/interfaces/external/pancake/IPancakeV3LmPool.sol";

interface IGigaMasterchefV3 {
    struct PoolInfo {
        uint256 allocPoint;
        address clPool;
        address token0;
        address token1;
        uint24 fee;
        uint256 totalLiquidity;
    }

    struct UserPositionInfo {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 rewardGrowthInside;
        uint256 reward;
        address user;
        uint256 pid;
        uint40 lastLiquidityChange;
    }

    function userPositionInfos(
        uint256 tokenId
    ) external view returns (UserPositionInfo memory);

    function poolInfo(
        uint256 pid
    ) external view returns (PoolInfo memory);

    function getLatestPeriodInfo(
        address pool
    ) external view returns (uint256 rewardPerSecond, uint256 endTime);
}

contract GigaMasterchefV3Connector is PancakeV3Connector {
    uint256 private constant Q128 = 0x100000000000000000000000000000000;
    uint256 private constant MAX_U256 = type(uint256).max;
    uint256 private constant REWARD_PRECISION = 1e12;

    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external override {
        IERC721Enumerable(position.nft)
            .safeTransferFrom(
                address(this), position.farm.stakingContract, position.tokenId
            );
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external override {
        IMasterchefV3(position.farm.stakingContract)
            .withdraw(position.tokenId, address(this));
    }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata // extraData
    ) external override {
        IMasterchefV3(position.farm.stakingContract)
            .harvest(position.tokenId, address(this));
        if (amount0Max > 0 || amount1Max > 0) {
            INonfungiblePositionManager.CollectParams memory params =
                INonfungiblePositionManager.CollectParams({
                    tokenId: position.tokenId,
                    recipient: address(this),
                    amount0Max: amount0Max,
                    amount1Max: amount1Max
                });
            INonfungiblePositionManager(position.farm.stakingContract)
                .collect(params);
        }
    }

    function isStaked(
        address user,
        NftPosition calldata position
    ) external view override returns (bool) {
        return IGigaMasterchefV3(position.farm.stakingContract)
            .userPositionInfos(position.tokenId)
            .user == user;
    }

    function earned(
        address, // user
        NftPosition calldata position,
        address[] memory // rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewardAmounts = new uint256[](1);

        IGigaMasterchefV3.UserPositionInfo memory positionInfo =
            IGigaMasterchefV3(position.farm.stakingContract)
                .userPositionInfos(position.tokenId);

        if (positionInfo.pid != 0) {
            IGigaMasterchefV3.PoolInfo memory pool = IGigaMasterchefV3(
                    position.farm.stakingContract
                ).poolInfo(positionInfo.pid);
            IPancakeV3LmPool LMPool =
                IPancakeV3LmPool(IPancakeV3Pool(pool.clPool).lmPool());

            if (address(LMPool) != address(0)) {
                // Always simulate what would happen after accumulateReward
                // This matches exactly what harvest does
                uint32 currentTime = uint32(block.timestamp);
                uint32 lastRewardTimestamp = LMPool.lastRewardTimestamp();
                uint128 lmLiquidity = LMPool.lmLiquidity();

                // Reward growth accumulateReward() would add if it ran now.
                uint256 pendingGrowthX128;
                if (lmLiquidity != 0 && currentTime > lastRewardTimestamp) {
                    (uint256 rewardPerSecond, uint256 endTime) = IMasterchefV3(
                            position.farm.stakingContract
                        ).getLatestPeriodInfo(pool.clPool);

                    uint32 endTimestamp = uint32(endTime);
                    uint32 duration;
                    if (endTimestamp > currentTime) {
                        duration = currentTime - lastRewardTimestamp;
                    } else if (endTimestamp > lastRewardTimestamp) {
                        duration = endTimestamp - lastRewardTimestamp;
                    }

                    if (duration != 0 && rewardPerSecond != 0) {
                        uint256 reward = rewardPerSecond * duration;
                        pendingGrowthX128 += (reward * Q128) / lmLiquidity
                            / REWARD_PRECISION;
                    }
                }

                // Get current state
                uint256 rewardGrowthInside = LMPool.getRewardGrowthInside(
                    positionInfo.tickLower, positionInfo.tickUpper
                );

                if (pendingGrowthX128 != 0) {
                    (, int24 tickCurrent,,,,,) =
                        IPancakeV3Pool(pool.clPool).slot0();

                    // Check if position is in range
                    if (
                        tickCurrent >= positionInfo.tickLower
                            && tickCurrent < positionInfo.tickUpper
                    ) {
                        // Position is in range, it earns the full global reward
                        // growth delta. The LM pool is Solidity 0.7 and keeps
                        // these Q128 accumulators mod 2**256, so add the same
                        // way accumulateReward() would.
                        unchecked {
                            rewardGrowthInside += pendingGrowthX128;
                        }
                    }
                }

                // MasterChefV3.harvestOperation() takes this difference
                // unchecked and pays out the modular result, so a wrapped
                // accumulator still yields the delta actually earned. Ordering
                // the two operands instead would drop that reward entirely.
                uint256 rewardGrowthInsideDelta;
                unchecked {
                    rewardGrowthInsideDelta =
                        rewardGrowthInside - positionInfo.rewardGrowthInside;
                }

                // MasterChefV3 multiplies this unguarded; bound it so the view
                // reports nothing rather than reverting where harvest would.
                if (
                    rewardGrowthInsideDelta != 0
                        && MAX_U256 / rewardGrowthInsideDelta
                            > positionInfo.liquidity
                ) {
                    rewardAmounts[0] =
                        (rewardGrowthInsideDelta * positionInfo.liquidity)
                            / Q128;
                }
            }

            // Add stored rewards
            rewardAmounts[0] += positionInfo.reward;
        }

        return rewardAmounts;
    }
}
