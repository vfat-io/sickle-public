// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    AddLiquidityParams,
    RemoveLiquidityParams,
    SwapParams
} from "contracts/structs/LiquidityStructs.sol";

interface ILiquidityConnector {
    error InvalidPrice();

    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external payable;

    function removeLiquidity(
        RemoveLiquidityParams memory removeLiquidityParams
    ) external;

    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external payable;

    function getPoolPrice(
        address lpToken,
        uint256 baseTokenIndex,
        uint256 quoteTokenIndex
    ) external view returns (uint256);

    function getReserves(
        address lpToken
    ) external view returns (uint256[] memory reserves);

    function getTokens(
        address lpToken
    ) external view returns (address[] memory tokens);
}
