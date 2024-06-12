// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import { IGauge } from "contracts/interfaces/external/aerodrome/IGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

contract AerodromeGaugeConnector is IFarmConnector {
    function deposit(
        address target,
        address token,
        bytes memory // _extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, target, amount);
        IGauge(target).deposit(amount);
    }

    function withdraw(
        address target,
        uint256 amount,
        bytes memory // _extraData
    ) external override {
        IGauge(target).withdraw(amount);
    }

    function claim(
        address target,
        bytes memory // _extraData
    ) external override {
        IGauge(target).getReward(address(this));
    }
}
