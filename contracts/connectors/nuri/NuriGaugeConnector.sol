// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { INuriGauge } from "contracts/interfaces/external/nuri/INuriGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { RamsesGaugeConnector } from
    "contracts/connectors/ramses/RamsesGaugeConnector.sol";

contract NuriGaugeConnector is RamsesGaugeConnector {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // _extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
        INuriGauge(farm.stakingContract).deposit(amount);
    }
}
