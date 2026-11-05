// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ThenaIncentiveMakerConnector } from
    "contracts/connectors/thena/ThenaIncentiveMakerConnector.sol";
import { IncentiveKey } from
    "contracts/interfaces/external/thena/IIncentiveMaker.sol";
import { IFarmingCenter } from
    "contracts/interfaces/external/thena/IFarmingCenter.sol";
import { NftPosition } from "contracts/interfaces/INftFarmConnector.sol";
import { IAlgebraEternalFarming } from
    "contracts/interfaces/external/thena/IAlgebraEternalFarming.sol";

interface IBlackholeGauge {
    function poolAddress() external view returns (address);
    function farmingCenter() external view returns (address);
}

interface IBlackholeFarmingCenter {
    function eternalFarming() external view returns (address);
}

interface IBlackholeEternalFarming {
    function incentiveKeys(
        address pool
    )
        external
        view
        returns (
            address rewardToken,
            address bonusRewardToken,
            address poolAddress,
            uint256 nonce
        );
}

contract BlackholeV3GaugeConnector is ThenaIncentiveMakerConnector {
    function _get_incentive_key_and_farming_center(
        NftPosition calldata position
    )
        internal
        view
        virtual
        override
        returns (IncentiveKey memory, IFarmingCenter)
    {
        IBlackholeGauge gauge = IBlackholeGauge(position.farm.stakingContract);
        IBlackholeFarmingCenter farmingCenter =
            IBlackholeFarmingCenter(gauge.farmingCenter());
        address eternalFarming = farmingCenter.eternalFarming();
        address pool = gauge.poolAddress();
        (address rewardToken, address bonusRewardToken,, uint256 nonce) =
            IBlackholeEternalFarming(eternalFarming).incentiveKeys(pool);
        return (
            IncentiveKey({
                rewardToken: rewardToken,
                bonusRewardToken: bonusRewardToken,
                pool: pool,
                nonce: nonce
            }),
            IFarmingCenter(gauge.farmingCenter())
        );
    }

    function earned(
        address, // user
        NftPosition calldata position,
        address[] memory // rewardTokens
    ) external view override returns (uint256[] memory) {
        (IncentiveKey memory incentiveKey, IFarmingCenter farmingCenter) =
            _get_incentive_key_and_farming_center(position);

        if (farmingCenter.deposits(position.tokenId) == bytes32(0)) {
            return new uint256[](0);
        }

        (uint256 reward,) = IAlgebraEternalFarming(
            farmingCenter.eternalFarming()
        ).getRewardInfo(incentiveKey, position.tokenId);

        uint256[] memory rewards = new uint256[](1);
        rewards[0] = reward;

        return rewards;
    }
}
