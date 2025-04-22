// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IMerchantMoeMasterchef } from
    "contracts/interfaces/external/merchant/IMerchantMoeMasterchef.sol";
import { MasterchefConnector } from
    "contracts/connectors/MasterchefConnector.sol";
import { Farm } from "contracts/interfaces/IFarmConnector.sol";

contract MerchantMoeMasterchefConnector is MasterchefConnector {
    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IMerchantMoeMasterchef(farm.stakingContract).getDeposit(
            farm.poolIndex, user
        );
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata // rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory pids = new uint256[](1);
        pids[0] = farm.poolIndex;
        (uint256[] memory moeRewards,,) = IMerchantMoeMasterchef(
            farm.stakingContract
        ).getPendingRewards(user, pids);
        return moeRewards;
    }
}
