// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import {
    ISwaphoodGauge
} from "contracts/interfaces/external/swaphood/ISwaphoodGauge.sol";

contract SwaphoodV2GaugeConnector is IFarmConnector {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // _extraData
    ) external override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
            ISwaphoodGauge(farm.stakingContract).stake(amount);
        }
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // _extraData
    ) external override {
        ISwaphoodGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory // extraData
    ) external override {
        ISwaphoodGauge(farm.stakingContract).getReward();
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return ISwaphoodGauge(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata // rewardTokens
    ) external view override returns (uint256[] memory) {
        // SwapHood gauges pay a single reward token (HOOD), so return a
        // length-1 array rather than duplicating the same amount across every
        // requested reward-token slot.
        uint256[] memory rewards = new uint256[](1);
        rewards[0] = ISwaphoodGauge(farm.stakingContract).earned(user);
        return rewards;
    }

    function isStaked(
        Farm calldata,
        address // user
    ) external pure override returns (bool) {
        return true;
    }
}
