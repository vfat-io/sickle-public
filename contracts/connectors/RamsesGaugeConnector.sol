// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IFarmConnector.sol";
import "../interfaces/external/ramses/IRamsesGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

struct RamsesClaimExtraData {
    address[] rewardTokens;
}

contract RamsesGaugeConnector is IFarmConnector {
    function deposit(
        address target,
        address token,
        bytes memory // _extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, target, amount);
        IRamsesGauge(target).deposit(amount, 0);
    }

    function withdraw(
        address target,
        uint256 amount,
        bytes memory // _extraData
    ) external override {
        IRamsesGauge(target).withdraw(amount);
    }

    function claim(address target, bytes memory _extraData) external override {
        RamsesClaimExtraData memory extraData =
            abi.decode(_extraData, (RamsesClaimExtraData));
        IRamsesGauge(target).claimFees();
        IRamsesGauge(target).getReward(address(this), extraData.rewardTokens);
    }
}
