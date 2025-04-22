// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBGT } from "contracts/interfaces/external/kodiak/IBGT.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { IKodiakRewardVault } from
    "contracts/interfaces/external/kodiak/IKodiakRewardVault.sol";

contract KodiakGaugeConnector is IFarmConnector {
    address constant BGT = 0x656b95E550C07a9ffe548bd4085c72418Ceb1dba;

    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // _extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
            IKodiakRewardVault(farm.stakingContract).stake(amount);
        }
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // _extraData
    ) external override {
        IKodiakRewardVault(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory // extraData
    ) external override {
        IKodiakRewardVault(farm.stakingContract).getReward(
            address(this), address(this)
        );
        uint256 rewards = IERC20(BGT).balanceOf(address(this));
        if (rewards > 0) {
            IBGT(BGT).redeem(address(this), rewards);
        }
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IKodiakRewardVault(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewards[i] = IKodiakRewardVault(farm.stakingContract).earned(user);
        }
        return rewards;
    }
}
