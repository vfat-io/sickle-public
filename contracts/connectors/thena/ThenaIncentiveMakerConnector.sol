// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    INftFarmConnector,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import { IThenaNonfungiblePositionManager } from
    "contracts/interfaces/external/thena/IThenaNonfungiblePositionManager.sol";
import { IThenaAlgebraFactory } from
    "contracts/interfaces/external/thena/IThenaAlgebraFactory.sol";
import {
    IIncentiveMaker,
    IncentiveKey
} from "contracts/interfaces/external/thena/IIncentiveMaker.sol";
import { IFarmingCenter } from
    "contracts/interfaces/external/thena/IFarmingCenter.sol";
import { IAlgebraEternalFarming } from
    "contracts/interfaces/external/thena/IAlgebraEternalFarming.sol";
import { IVirtualFarmingPool } from
    "contracts/interfaces/external/thena/IVirtualFarmingPool.sol";
import { FullMath } from
    "contracts/interfaces/external/uniswap/v3/libraries/FullMath.sol";
import { FixedPoint128 } from
    "contracts/interfaces/external/uniswap/v3/libraries/FixedPoint128.sol";
import { PositionValue } from
    "contracts/interfaces/external/uniswap/v3/PositionValue.sol";

interface IThenaBasePlugin {
    function incentive() external view returns (address);
}

interface IThenaV3Pool {
    function plugin() external view returns (address);
}

contract ThenaIncentiveMakerConnector is INftFarmConnector, PositionValue {
    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external override {
        (IncentiveKey memory incentiveKey, IFarmingCenter farmingCenter) =
            _get_incentive_key_and_farming_center(position);
        if (farmingCenter.deposits(position.tokenId) == bytes32(0)) {
            IThenaNonfungiblePositionManager(address(position.nft))
                .approveForFarming(position.tokenId, true, address(farmingCenter));
            farmingCenter.enterFarming(incentiveKey, position.tokenId);
        }
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external override {
        (IncentiveKey memory incentiveKey, IFarmingCenter farmingCenter) =
            _get_incentive_key_and_farming_center(position);
        if (farmingCenter.deposits(position.tokenId) != bytes32(0)) {
            farmingCenter.exitFarming(incentiveKey, position.tokenId);
        }
    }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128, // maxAmount0
        uint128, // maxAmount1
        bytes calldata // extraData
    ) external override {
        if (!_isTokenStaked(position)) {
            return;
        }

        (IncentiveKey memory incentiveKey, IFarmingCenter farmingCenter) =
            _get_incentive_key_and_farming_center(position);
        (uint256 reward, uint256 bonusReward) =
            farmingCenter.collectRewards(incentiveKey, position.tokenId);
        if (reward > 0) {
            farmingCenter.claimReward(
                incentiveKey.rewardToken, address(this), reward
            );
        }
        if (bonusReward > 0) {
            farmingCenter.claimReward(
                incentiveKey.bonusRewardToken, address(this), bonusReward
            );
        }
    }

    /// @dev Token-level: is this position in farming at all, whoever owns it.
    /// `claim` and `earned` only need that much — they ask "is there anything
    /// to collect", not "who controls it" — so they call this rather than the
    /// user-bound `isStaked` below, which would reject them for passing a zero
    /// user.
    function _isTokenStaked(
        NftPosition calldata position
    ) internal view returns (bool) {
        IIncentiveMaker incentiveMaker =
            IIncentiveMaker(position.farm.stakingContract);
        IFarmingCenter farmingCenter =
            IFarmingCenter(incentiveMaker.farmingCenter());
        return farmingCenter.deposits(position.tokenId) != bytes32(0);
    }

    /// @dev Bound to `user`. Algebra farming takes no custody --
    /// `approveForFarming` leaves the NFT with its owner -- so `ownerOf` is the
    /// control record and has to be part of the answer. Taking no custody does
    /// not make this unreachable: settings outlive a position that leaves the
    /// Sickle, and if its new owner re-enters farming, `ownerOf` matches
    /// neither the Sickle nor its owner and callers land here.
    function isStaked(
        address user,
        NftPosition calldata position
    ) public view override returns (bool) {
        return position.nft.ownerOf(position.tokenId) == user
            && _isTokenStaked(position);
    }

    function earned(
        address, // user
        NftPosition calldata position,
        address[] memory // rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        if (!_isTokenStaked(position)) {
            return new uint256[](2);
        }

        (IncentiveKey memory incentiveKey, IFarmingCenter farmingCenter) =
            _get_incentive_key_and_farming_center(position);

        address virtualPool = IThenaBasePlugin(
            IThenaV3Pool(incentiveKey.pool).plugin()
        ).incentive();

        IVirtualFarmingPool vPool = IVirtualFarmingPool(virtualPool);

        (uint256 pendingReward0, uint256 pendingReward1) =
        _calculate_pending_rewards(position, vPool, farmingCenter, incentiveKey);

        (uint256 reward, uint256 bonusReward) = IAlgebraEternalFarming(
            farmingCenter.eternalFarming()
        ).getRewardInfo(incentiveKey, position.tokenId);

        uint256[] memory rewards = new uint256[](2);
        rewards[0] = reward + pendingReward0;
        rewards[1] = bonusReward + pendingReward1;

        return rewards;
    }

    function _get_current_tick(
        address pool
    ) internal view virtual override returns (int24 tickCurrent) {
        tickCurrent = IVirtualFarmingPool(pool).globalTick();
    }

    function _calculate_pending_rewards(
        NftPosition calldata position,
        IVirtualFarmingPool vPool,
        IFarmingCenter farmingCenter,
        IncentiveKey memory incentiveKey
    ) internal view returns (uint256 pendingReward0, uint256 pendingReward1) {
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) =
        IThenaNonfungiblePositionManager(address(position.nft)).positions(
            position.tokenId
        );

        (uint256 rewardGrowthInside0, uint256 rewardGrowthInside1) =
            _get_fee_growth_inside(address(vPool), tickLower, tickUpper);

        uint128 positionLiquidity =
            _get_position_liquidity(position, farmingCenter, incentiveKey);

        pendingReward0 = FullMath.mulDiv(
            rewardGrowthInside0, positionLiquidity, FixedPoint128.Q128
        );
        pendingReward1 = FullMath.mulDiv(
            rewardGrowthInside1, positionLiquidity, FixedPoint128.Q128
        );
    }

    // Calculate reward growth including current time delta
    function _get_fee_growth_global(
        address pool
    )
        internal
        view
        virtual
        override
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)
    {
        uint32 currTimestamp = uint32(block.timestamp);
        uint32 prevTimestamp = IVirtualFarmingPool(pool).prevTimestamp();
        uint128 currentLiquidity = IVirtualFarmingPool(pool).currentLiquidity();
        (feeGrowthGlobal0, feeGrowthGlobal1) =
            IVirtualFarmingPool(pool).totalRewardGrowth();
        (uint128 rewardRate0, uint128 rewardRate1) =
            IVirtualFarmingPool(pool).rewardRates();
        (uint128 rewardReserve0, uint128 rewardReserve1) =
            IVirtualFarmingPool(pool).rewardReserves();

        if (currentLiquidity > 0) {
            uint256 timeDelta = currTimestamp - prevTimestamp;

            if (timeDelta > 0) {
                uint256 reward0 = rewardRate0 * timeDelta;
                uint256 reward1 = rewardRate1 * timeDelta;

                if (reward0 > rewardReserve0) reward0 = rewardReserve0;
                if (reward1 > rewardReserve1) reward1 = rewardReserve1;

                if (reward0 > 0) {
                    feeGrowthGlobal0 += FullMath.mulDiv(
                        reward0, FixedPoint128.Q128, currentLiquidity
                    );
                }
                if (reward1 > 0) {
                    feeGrowthGlobal1 += FullMath.mulDiv(
                        reward1, FixedPoint128.Q128, currentLiquidity
                    );
                }
            }
        }
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
        (,,,, feeGrowthOutside0X128, feeGrowthOutside1X128) =
            IVirtualFarmingPool(pool).ticks(tick);
    }

    function _get_position_liquidity(
        NftPosition calldata position,
        IFarmingCenter farmingCenter,
        IncentiveKey memory incentiveKey
    ) internal view returns (uint128 positionLiquidity) {
        (positionLiquidity,,,,) = IAlgebraEternalFarming(
            farmingCenter.eternalFarming()
        ).farms(
            position.tokenId,
            keccak256(
                abi.encodePacked(
                    incentiveKey.rewardToken,
                    incentiveKey.bonusRewardToken,
                    incentiveKey.pool,
                    incentiveKey.nonce
                )
            )
        );
    }

    function _get_incentive_key_and_farming_center(
        NftPosition calldata position
    ) internal view virtual returns (IncentiveKey memory, IFarmingCenter) {
        IIncentiveMaker incentiveMaker =
            IIncentiveMaker(position.farm.stakingContract);
        IThenaNonfungiblePositionManager nonfungiblePositionManager =
            IThenaNonfungiblePositionManager(address(position.nft));
        (,, address token0, address token1,,,,,,,,) =
            nonfungiblePositionManager.positions(position.tokenId);
        address pool = IThenaAlgebraFactory(
            nonfungiblePositionManager.factory()
        ).poolByPair(token0, token1);
        (address rewardToken, address bonusRewardToken,, uint256 nonce) =
            incentiveMaker.poolToKey(pool);
        return (
            IncentiveKey({
                rewardToken: rewardToken,
                bonusRewardToken: bonusRewardToken,
                pool: pool,
                nonce: nonce
            }),
            IFarmingCenter(incentiveMaker.farmingCenter())
        );
    }
}
