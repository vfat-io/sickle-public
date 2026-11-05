// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/structs/LiquidityStructs.sol";

interface ILiquidityConnector {
    error InvalidPrice();

    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external;

    function removeLiquidity(
        RemoveLiquidityParams memory removeLiquidityParams
    ) external;

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
