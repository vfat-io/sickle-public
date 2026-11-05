// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    IHyperstableGauge
} from "contracts/interfaces/external/hyperstable/IHyperstableGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

struct HyperstableClaimExtraData {
    address[] rewardTokens;
}

/// @dev Hyperstable gauges are Velodrome V1 gauges: `deposit(amount, tokenId)`
/// with no vePEG boost, multi-token `getReward`/`earned`. Unlike
/// RamsesGaugeConnector, claim does not call the gauge's `claimFees()`: it is
/// team-only here ("only team") and pool fees go to the bribe, not the staker.
contract HyperstableGaugeConnector is IFarmConnector {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // extraData
    ) external override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
            IHyperstableGauge(farm.stakingContract).deposit(amount, 0);
        }
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // extraData
    ) external override {
        IHyperstableGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory extraData
    ) external override {
        HyperstableClaimExtraData memory claimData =
            abi.decode(extraData, (HyperstableClaimExtraData));
        IHyperstableGauge(farm.stakingContract)
            .getReward(address(this), claimData.rewardTokens);
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IHyperstableGauge(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewards[i] = IHyperstableGauge(farm.stakingContract)
                .earned(rewardTokens[i], user);
        }
        return rewards;
    }

    function isStaked(
        Farm calldata,
        address // user
    ) external pure override returns (bool) {
        return true;
    }
}
