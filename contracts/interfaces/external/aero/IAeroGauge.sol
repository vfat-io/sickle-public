// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAeroGauge {
    function deposit(
        uint256 amount
    ) external;

    function withdraw(
        uint256 amount
    ) external;

    function claimEmissions(
        address account,
        address recipient
    ) external;

    function earned(
        address account
    ) external view returns (uint256);
}

interface IAeroV2Gauge is IAeroGauge {
    function stakingToken() external view returns (address);

    function balanceOf(
        address account
    ) external view returns (uint256);
}
