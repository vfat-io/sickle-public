// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from
    "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { IMasterchef } from "contracts/interfaces/external/IMasterchef.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

contract MasterchefConnector is IFarmConnector {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // extraData
    ) external payable virtual override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
        IMasterchef(farm.stakingContract).deposit(farm.poolIndex, amount);
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // extraData
    ) external override {
        IMasterchef(farm.stakingContract).withdraw(farm.poolIndex, amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory // extraData
    ) external override {
        IMasterchef(farm.stakingContract).deposit(farm.poolIndex, 0);
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view virtual override returns (uint256) {
        (uint256 amount,) =
            IMasterchef(farm.stakingContract).userInfo(farm.poolIndex, user);
        return amount;
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata
    ) external view virtual override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](1);
        (, uint256 pendingRewards) =
            IMasterchef(farm.stakingContract).userInfo(farm.poolIndex, user);
        rewards[0] = pendingRewards;
        return rewards;
    }
}
