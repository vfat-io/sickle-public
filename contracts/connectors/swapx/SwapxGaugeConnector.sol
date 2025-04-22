// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Farm } from "contracts/interfaces/IFarmConnector.sol";
import { ISwapxGauge } from
    "contracts/interfaces/external/swapx/ISwapxGauge.sol";
import { NuriGaugeConnector } from
    "contracts/connectors/nuri/NuriGaugeConnector.sol";

contract SwapxGaugeConnector is NuriGaugeConnector {
    function earned(
        Farm calldata farm,
        address user,
        address[] calldata // rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](1);
        rewards[0] = ISwapxGauge(farm.stakingContract).earned(user);
        return rewards;
    }

    function claim(Farm memory farm, bytes memory) external override {
        ISwapxGauge(farm.stakingContract).claimFees();
        ISwapxGauge(farm.stakingContract).getReward();
    }
}
