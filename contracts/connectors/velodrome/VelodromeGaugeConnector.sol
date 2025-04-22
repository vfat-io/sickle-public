// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { IGauge } from "contracts/interfaces/external/aerodrome/IGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

contract VelodromeGaugeConnector is IFarmConnector {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
        IGauge(farm.stakingContract).deposit(amount);
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // extraData
    ) external override {
        IGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm memory farm,
        bytes memory // extraData
    ) external override {
        IGauge(farm.stakingContract).getReward(address(this));
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IGauge(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata // rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](1);
        rewards[0] = IGauge(farm.stakingContract).earned(user);
        return rewards;
    }
}
