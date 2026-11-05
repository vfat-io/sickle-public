// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ThenaIncentiveMakerConnector
} from "contracts/connectors/thena/ThenaIncentiveMakerConnector.sol";
import { NftPosition } from "contracts/interfaces/INftFarmConnector.sol";
import {
    IAtlantisIncentiveMaker
} from "contracts/interfaces/external/atlantis/IAtlantisIncentiveMaker.sol";
import {
    IncentiveKey
} from "contracts/interfaces/external/thena/IIncentiveMaker.sol";
import {
    IFarmingCenter
} from "contracts/interfaces/external/thena/IFarmingCenter.sol";
import {
    IThenaNonfungiblePositionManager
} from "contracts/interfaces/external/thena/IThenaNonfungiblePositionManager.sol";
import {
    IThenaAlgebraFactory
} from "contracts/interfaces/external/thena/IThenaAlgebraFactory.sol";
import {
    IAlgebraEternalFarming
} from "contracts/interfaces/external/thena/IAlgebraEternalFarming.sol";

contract AtlantisIncentiveMakerConnector is ThenaIncentiveMakerConnector {
    function _get_incentive_key_and_farming_center(
        NftPosition calldata position
    ) internal view override returns (IncentiveKey memory, IFarmingCenter) {
        IAtlantisIncentiveMaker incentiveMaker =
            IAtlantisIncentiveMaker(position.farm.stakingContract);
        IThenaNonfungiblePositionManager positionManager =
            IThenaNonfungiblePositionManager(address(position.nft));
        (,, address token0, address token1,,,,,,,,) =
            positionManager.positions(position.tokenId);
        address pool = IThenaAlgebraFactory(positionManager.factory())
            .poolByPair(token0, token1);
        (address rewardToken, address bonusRewardToken,, uint256 nonce) =
            incentiveMaker.incentiveKeys(pool);
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

    function earned(
        address, // user
        NftPosition calldata position,
        address[] memory // rewardTokens
    ) external view override returns (uint256[] memory) {
        if (!_isTokenStaked(position)) {
            return new uint256[](2);
        }

        (IncentiveKey memory incentiveKey, IFarmingCenter farmingCenter) =
            _get_incentive_key_and_farming_center(position);

        (uint256 reward, uint256 bonusReward) = IAlgebraEternalFarming(
                farmingCenter.eternalFarming()
            ).getRewardInfo(incentiveKey, position.tokenId);

        uint256[] memory rewards = new uint256[](2);
        rewards[0] = reward;
        rewards[1] = bonusReward;

        return rewards;
    }
}
