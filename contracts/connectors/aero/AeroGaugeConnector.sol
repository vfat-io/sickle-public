// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    IAeroGauge,
    IAeroV2Gauge
} from "contracts/interfaces/external/aero/IAeroGauge.sol";
import { IAeroPool } from "contracts/interfaces/external/aero/IAeroPool.sol";

/// @notice Connector for Aero MetaDEX V2 gauges. The new gauge reward method
/// is claimEmissions(account, recipient), unlike legacy Aerodrome getReward.
contract AeroGaugeConnector is IFarmConnector {
    error InvalidStakingToken();

    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // extraData
    ) external override {
        if (IAeroV2Gauge(farm.stakingContract).stakingToken() != token) {
            revert InvalidStakingToken();
        }
        // Moving all LP to the gauge updates but does not pay the Sickle's
        // direct pool-fee accrual. Claim it before the balance leaves.
        IAeroPool(token).claimFees(address(this));
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, farm.stakingContract, 0);
        SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
        IAeroGauge(farm.stakingContract).deposit(amount);
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // extraData
    ) external override {
        IAeroGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory // extraData
    ) external override {
        IAeroGauge(farm.stakingContract)
            .claimEmissions(address(this), address(this));
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IAeroV2Gauge(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata // rewardTokens
    ) external view override returns (uint256[] memory rewards) {
        rewards = new uint256[](1);
        rewards[0] = IAeroGauge(farm.stakingContract).earned(user);
    }

    function isStaked(
        Farm calldata farm,
        address user
    ) external view override returns (bool) {
        return IAeroV2Gauge(farm.stakingContract).balanceOf(user) != 0;
    }
}
