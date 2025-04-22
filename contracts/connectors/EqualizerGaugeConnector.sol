// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { IEqualizerGauge } from
    "contracts/interfaces/external/equalizer/IEqualizerGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

struct EqualizerExtraData {
    address[] rewardTokens;
}

contract EqualizerGaugeConnector is IFarmConnector {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // _extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
            IEqualizerGauge(farm.stakingContract).deposit(amount);
        }
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // _extraData
    ) external override {
        IEqualizerGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory extraData
    ) external override {
        EqualizerExtraData memory equalizerextraData =
            abi.decode(extraData, (EqualizerExtraData));
        IEqualizerGauge(farm.stakingContract).getReward(
            address(this), equalizerextraData.rewardTokens
        );
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IEqualizerGauge(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewards[i] = IEqualizerGauge(farm.stakingContract).earned(
                rewardTokens[i], user
            );
        }
        return rewards;
    }
}
