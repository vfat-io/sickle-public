// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { INuriGauge } from "contracts/interfaces/external/nuri/INuriGauge.sol";

import {
    ShadowRewardBehavior,
    ShadowV2GaugeClaim
} from "contracts/connectors/shadow/ShadowGaugeClaim.sol";

struct ShadowClaimExtraData {
    address[] claimTokens;
    ShadowRewardBehavior behavior;
}

contract ShadowV2GaugeConnector is IFarmConnector, ShadowV2GaugeClaim {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // _extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
        INuriGauge(farm.stakingContract).deposit(amount);
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // _extraData
    ) external override {
        INuriGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory extraData
    ) external override {
        ShadowClaimExtraData memory extra =
            abi.decode(extraData, (ShadowClaimExtraData));

        _claimGaugeRewards(
            farm.stakingContract, extra.claimTokens, extra.behavior
        );
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return INuriGauge(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewards[i] =
                INuriGauge(farm.stakingContract).earned(rewardTokens[i], user);
        }
        return rewards;
    }
}
