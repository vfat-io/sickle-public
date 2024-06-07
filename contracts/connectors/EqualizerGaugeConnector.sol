// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IFarmConnector.sol";
import "../interfaces/external/equalizer/IEqualizerGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

struct EqualizerExtraData {
    address[] rewardTokens;
}

contract EqualizerGaugeConnector is IFarmConnector {
    function deposit(
        address target,
        address token,
        bytes memory // _extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            SafeTransferLib.safeApprove(token, target, amount);
            IEqualizerGauge(target).deposit(amount);
        }
    }

    function withdraw(
        address target,
        uint256 amount,
        bytes memory // _extraData
    ) external override {
        IEqualizerGauge(target).withdraw(amount);
    }

    function claim(address target, bytes memory extraData) external override {
        EqualizerExtraData memory equalizerextraData =
            abi.decode(extraData, (EqualizerExtraData));
        IEqualizerGauge(target).getReward(
            address(this), equalizerextraData.rewardTokens
        );
    }
}
