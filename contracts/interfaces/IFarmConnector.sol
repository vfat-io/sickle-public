// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Farm } from "contracts/structs/FarmStrategyStructs.sol";

interface IFarmConnector {
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory extraData
    ) external payable;

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory extraData
    ) external;

    function claim(Farm calldata farm, bytes memory extraData) external;

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view returns (uint256);

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view returns (uint256[] memory);
}
