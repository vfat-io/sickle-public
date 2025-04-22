// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IFenixGauge {
    function deposit(
        uint256 amount
    ) external;

    function withdraw(
        uint256 amount
    ) external;

    function getReward() external;

    function balanceOf(
        address user
    ) external view returns (uint256);

    function earned(
        address user
    ) external view returns (uint256);
}
