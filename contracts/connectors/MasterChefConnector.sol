// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IFarmConnector.sol";
import "../interfaces/external/IMasterChef.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

struct MasterChefExtraData {
    uint256 pid;
    address referrer;
}

contract MasterChefConnector is IFarmConnector {
    function deposit(
        address target,
        address token,
        bytes memory extraData
    ) external payable virtual override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, target, amount);
        MasterChefExtraData memory masterChefExtraData =
            abi.decode(extraData, (MasterChefExtraData));
        IMasterChef(target).deposit(masterChefExtraData.pid, amount);
    }

    function withdraw(
        address target,
        uint256 amount,
        bytes memory extraData
    ) external override {
        MasterChefExtraData memory masterChefExtraData =
            abi.decode(extraData, (MasterChefExtraData));
        IMasterChef(target).withdraw(masterChefExtraData.pid, amount);
    }

    function claim(address target, bytes memory extraData) external override {
        MasterChefExtraData memory masterChefExtraData =
            abi.decode(extraData, (MasterChefExtraData));
        IMasterChef(target).deposit(masterChefExtraData.pid, 0);
    }
}
