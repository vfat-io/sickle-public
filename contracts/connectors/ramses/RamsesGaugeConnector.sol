// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { IRamsesGauge } from
    "contracts/interfaces/external/ramses/IRamsesGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

struct RamsesClaimExtraData {
    address[] rewardTokens;
}

contract RamsesGaugeConnector is IFarmConnector {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // _extraData
    ) external payable virtual override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
        IRamsesGauge(farm.stakingContract).deposit(amount, 0);
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // _extraData
    ) external override {
        IRamsesGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory _extraData
    ) external virtual override {
        RamsesClaimExtraData memory extraData =
            abi.decode(_extraData, (RamsesClaimExtraData));
        IRamsesGauge(farm.stakingContract).claimFees();
        IRamsesGauge(farm.stakingContract).getReward(
            address(this), extraData.rewardTokens
        );
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IRamsesGauge(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewards[i] =
                IRamsesGauge(farm.stakingContract).earned(rewardTokens[i], user);
        }
        return rewards;
    }
}
