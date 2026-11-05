// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ICurveStableNgSwapFactory {
    function get_coins(
        address pool
    ) external view returns (address[] memory);
}

interface ICurveStableNgSwapPool {
    function exchange(
        int128 i,
        int128 j,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external returns (uint256);
}
