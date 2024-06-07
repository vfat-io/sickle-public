// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./MasterChefConnector.sol";

contract MasterChefWithReferrerConnector is MasterChefConnector {
    constructor() { }

    function deposit(
        address target,
        address token,
        bytes memory extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, target, amount);
        MasterChefExtraData memory masterChefExtraData =
            abi.decode(extraData, (MasterChefExtraData));
        IMasterChef(target).deposit(
            masterChefExtraData.pid, amount, masterChefExtraData.referrer
        );
    }
}
