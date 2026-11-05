// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";
import {
    BinAddLiquidity,
    BinRemoveLiquidity
} from "contracts/structs/BinFarmStrategyStructs.sol";

/// @title IBinLiquidityConnector
/// @notice Interface for connectors that handle Liquidity Book (bin-based)
/// liquidity operations
interface IBinLiquidityConnector {
    /// @notice Adds liquidity to a Liquidity Book pair
    /// @param params The parameters for adding liquidity
    /// @return depositIds Array of bin IDs that received liquidity
    /// @return liquidityMinted Array of liquidity amounts minted per bin
    function addLiquidity(
        BinAddLiquidity calldata params
    )
        external
        returns (uint256[] memory depositIds, uint256[] memory liquidityMinted);

    /// @notice Removes liquidity from a Liquidity Book pair
    /// @param params The parameters for removing liquidity
    /// @return amountX Amount of tokenX received
    /// @return amountY Amount of tokenY received
    function removeLiquidity(
        BinRemoveLiquidity calldata params
    ) external returns (uint256 amountX, uint256 amountY);

    /// @notice Gets the bin step of a pair
    /// @param lbPair The Liquidity Book pair
    /// @return The bin step
    function binStep(
        ILBPair lbPair
    ) external view returns (uint16);

    /// @notice Gets the active bin ID of a pair
    /// @param lbPair The Liquidity Book pair
    /// @return The active bin ID
    function activeId(
        ILBPair lbPair
    ) external view returns (uint24);

    /// @notice Gets the balances of multiple bins for an account
    /// @param lbPair The Liquidity Book pair
    /// @param account The account to query
    /// @param ids Array of bin IDs to query
    /// @return balances Array of balances for each bin ID
    function binBalances(
        ILBPair lbPair,
        address account,
        uint256[] calldata ids
    ) external view returns (uint256[] memory balances);

    /// @notice Gets the total balance across all bins for an account
    /// @param lbPair The Liquidity Book pair
    /// @param account The account to query
    /// @param ids Array of bin IDs to sum
    /// @return total Total liquidity balance
    function totalBinBalance(
        ILBPair lbPair,
        address account,
        uint256[] calldata ids
    ) external view returns (uint256 total);

    /// @notice Calculates the underlying token amounts for a given liquidity
    /// position @param lbPair The Liquidity Book pair
    /// @param ids Array of bin IDs
    /// @param amounts Array of liquidity amounts per bin
    /// @return amountX Underlying tokenX amount
    /// @return amountY Underlying tokenY amount
    function underlyingAmounts(
        ILBPair lbPair,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external view returns (uint256 amountX, uint256 amountY);
}
