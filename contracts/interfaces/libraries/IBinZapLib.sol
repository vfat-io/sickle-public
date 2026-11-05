// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    BinAddLiquidity,
    BinZapOut
} from "contracts/structs/BinFarmStrategyStructs.sol";

/// @title IBinZapLib
/// @notice Interface for the Bin (Liquidity Book) zap library
interface IBinZapLib {
    /// @notice Adds liquidity and verifies the requested and minted bins.
    /// @dev Callers measure the minted share balances around this call.
    function addLiquidityChecked(
        BinAddLiquidity memory params,
        uint256[] memory expectedBinIds
    ) external payable;

    /// @notice Performs a zap-out operation for Liquidity Book
    /// @dev Removes liquidity from bin positions and swaps tokens
    /// @param zap The zap-out parameters including liquidity params and swaps
    /// @return amountX Amount of tokenX received
    /// @return amountY Amount of tokenY received
    function zapOut(
        BinZapOut memory zap
    ) external returns (uint256 amountX, uint256 amountY);
}
