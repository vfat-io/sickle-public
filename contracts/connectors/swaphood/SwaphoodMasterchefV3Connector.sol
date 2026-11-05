// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IERC721Enumerable
} from "@openzeppelin/contracts/interfaces/IERC721Enumerable.sol";

import { NftPosition } from "contracts/interfaces/INftFarmConnector.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { IMasterchefV3 } from "contracts/interfaces/external/IMasterchefV3.sol";
import {
    IPancakeV3Pool
} from "contracts/interfaces/external/pancake/IPancakeV3Pool.sol";
import {
    IPancakeV3LmPool
} from "contracts/interfaces/external/pancake/IPancakeV3LmPool.sol";
import {
    PancakeV3Connector
} from "contracts/connectors/pancake/PancakeV3Connector.sol";

contract SwaphoodMasterchefV3Connector is PancakeV3Connector {
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
        return IMasterchefV3(position.farm.stakingContract)
            .userPositionInfos(position.tokenId)
            .user == user;
    }

    function earned(
        address, // user
        NftPosition calldata position,
        address[] memory // rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewardAmounts = new uint256[](1);

        IMasterchefV3.UserPositionInfo memory positionInfo = IMasterchefV3(
                position.farm.stakingContract
            ).userPositionInfos(position.tokenId);

        if (positionInfo.pid != 0) {
            IMasterchefV3.PoolInfo memory pool = IMasterchefV3(
                    position.farm.stakingContract
                ).poolInfo(positionInfo.pid);
            IPancakeV3LmPool LMPool =
                IPancakeV3LmPool(IPancakeV3Pool(pool.v3Pool).lmPool());

            if (address(LMPool) != address(0)) {
                // Always simulate what would happen after accumulateReward
                // This matches exactly what harvest does
                uint32 currentTime = uint32(block.timestamp);
                uint32 lastRewardTimestamp = LMPool.lastRewardTimestamp();
                uint128 lmLiquidity = LMPool.lmLiquidity();
                uint256 rewardGrowthGlobalX128 = LMPool.rewardGrowthGlobalX128();

                // Update reward growth if time has passed and there's liquidity
                if (lmLiquidity != 0 && currentTime > lastRewardTimestamp) {
                    (uint256 rewardPerSecond,) = IMasterchefV3(
                            position.farm.stakingContract
                        ).getLatestPeriodInfo(pool.v3Pool);

                    // Unlike PancakeMasterchefV3Connector, the elapsed
                    // duration is not capped at the reward period's endTime:
                    // SwapHood's LmPool continues accruing rewards after the
                    // configured reward period ends.
                    uint32 duration = currentTime - lastRewardTimestamp;

                    if (duration != 0 && rewardPerSecond != 0) {
                        uint256 reward = rewardPerSecond * duration;
                        rewardGrowthGlobalX128 += (reward * Q128) / lmLiquidity
                            / REWARD_PRECISION;
                    }
                }

                // Get current state
                uint256 rewardGrowthInside = LMPool.getRewardGrowthInside(
                    positionInfo.tickLower, positionInfo.tickUpper
                );

                if (rewardGrowthGlobalX128 > LMPool.rewardGrowthGlobalX128()) {
                    // Time has passed, we need to account for new rewards
                    (, int24 tickCurrent,,,,,) =
                        IPancakeV3Pool(pool.v3Pool).slot0();

                    // Check if position is in range
                    if (
                        tickCurrent >= positionInfo.tickLower
                            && tickCurrent < positionInfo.tickUpper
                    ) {
                        // Position is in range, it earns the full global reward
                        // growth delta
                        uint256 deltaGlobal = rewardGrowthGlobalX128
                            - LMPool.rewardGrowthGlobalX128();
                        rewardGrowthInside += deltaGlobal;
                    }
                }

                // Check overflow and calculate reward
                if (
                    rewardGrowthInside > positionInfo.rewardGrowthInside
                        && MAX_U256
                                / (rewardGrowthInside
                                    - positionInfo.rewardGrowthInside)
                            > positionInfo.boostLiquidity
                ) {
                    rewardAmounts[0] =
                        ((rewardGrowthInside - positionInfo.rewardGrowthInside)
                                * positionInfo.boostLiquidity) / Q128;
                }
            }

            // Add stored rewards
            rewardAmounts[0] += positionInfo.reward;
        }

        return rewardAmounts;
    }
}
