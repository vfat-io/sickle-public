// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { IFenixGauge } from
    "contracts/interfaces/external/fenix/IFenixGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

contract ThenaGaugeConnector is IFarmConnector {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
        IFenixGauge(farm.stakingContract).deposit(amount);
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory
    ) external override {
        IFenixGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(Farm memory farm, bytes memory) external override {
        IFenixGauge(farm.stakingContract).getReward();
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IFenixGauge(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](1);
        rewards[0] = IFenixGauge(farm.stakingContract).earned(user);
        return rewards;
    }
}
