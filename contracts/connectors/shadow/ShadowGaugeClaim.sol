// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IShadowGaugeV3 } from
    "contracts/interfaces/external/shadow/IShadowGaugeV3.sol";
import { INuriGauge } from "contracts/interfaces/external/nuri/INuriGauge.sol";

interface IXShadow {
    function exit(
        uint256 amount
    ) external returns (uint256 exitedAmount);
}

interface IX33 {
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);
}

enum ShadowRewardBehavior {
    Exit, // Exit to Shadow (50% penalty)
    X33, // Deposit into X33
    Keep // Keep in xShadow on Sickle

}

contract ShadowAddresses {
    address constant X_SHADOW = 0x5050bc082FF4A74Fb6B0B04385dEfdDB114b2424;
    address constant X33_ADAPTER = 0x9710E10A8f6FbA8C391606fee18614885684548d;
}

contract ShadowV3GaugeClaim is ShadowAddresses {
    // Shadow rewards are in xShadow, which is not transferable.
    // When claiming, there are three options:
    // 1. Exit to Shadow (50% penalty)
    // 2. Deposit into X33 (no penalty)
    // 3. Keep in xShadow on Sickle
    // This function supports all three options.
    function _claimGaugeRewards(
        address gauge,
        uint256 tokenId,
        address[] memory rewardTokens,
        ShadowRewardBehavior behavior
    ) internal {
        IShadowGaugeV3(gauge).getReward(tokenId, rewardTokens);
        uint256 rewards = IERC20(X_SHADOW).balanceOf(address(this));
        if (rewards > 0) {
            if (behavior == ShadowRewardBehavior.X33) {
                IERC20(X_SHADOW).approve(X33_ADAPTER, rewards);
                IX33(X33_ADAPTER).deposit(rewards, address(this));
            } else if (behavior == ShadowRewardBehavior.Exit) {
                IXShadow(X_SHADOW).exit(rewards);
            } // else keep in xShadow on Sickle
        }
    }
}

contract ShadowV2GaugeClaim is ShadowAddresses {
    function _claimGaugeRewards(
        address gauge,
        address[] memory rewardTokens,
        ShadowRewardBehavior behavior
    ) internal {
        INuriGauge(gauge).getReward(address(this), rewardTokens);
        uint256 rewards = IERC20(X_SHADOW).balanceOf(address(this));
        if (rewards > 0) {
            if (behavior == ShadowRewardBehavior.X33) {
                IERC20(X_SHADOW).approve(X33_ADAPTER, rewards);
                IX33(X33_ADAPTER).deposit(rewards, address(this));
            } else if (behavior == ShadowRewardBehavior.Exit) {
                IXShadow(X_SHADOW).exit(rewards);
            } // else keep in xShadow on Sickle
        }
    }
}
