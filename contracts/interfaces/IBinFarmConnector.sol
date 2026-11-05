// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";
import { BinPosition } from "contracts/structs/BinFarmStrategyStructs.sol";

/// @title IBinFarmConnector
/// @notice Interface for connectors that handle Liquidity Book farm/gauge
/// staking operations
interface IBinFarmConnector {
    /// @notice Deposits LB tokens into a farm/gauge
    /// @param position The bin position details
    /// @param ids Array of bin IDs to deposit
    /// @param amounts Array of amounts to deposit per bin
    /// @param extraData Additional data for the deposit
    function deposit(
        BinPosition calldata position,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata extraData
    ) external;

    /// @notice Withdraws LB tokens from a farm/gauge
    /// @param position The bin position details
    /// @param ids Array of bin IDs to withdraw
    /// @param amounts Array of amounts to withdraw per bin
    /// @param extraData Additional data for the withdrawal
    function withdraw(
        BinPosition calldata position,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata extraData
    ) external;

    /// @notice Claims rewards from a farm/gauge
    /// @param position The bin position details
    /// @param extraData Additional data for claiming
    function claim(
        BinPosition calldata position,
        bytes calldata extraData
    ) external;

    /// @notice Gets the staked balance for an account
    /// @param position The bin position details
    /// @param user The account to query
    /// @param ids Array of bin IDs to query
    /// @return balances Array of staked balances per bin
    function balanceOf(
        BinPosition calldata position,
        address user,
        uint256[] calldata ids
    ) external view returns (uint256[] memory balances);

    /// @notice Gets the earned rewards for an account
    /// @param position The bin position details
    /// @param user The account to query
    /// @param rewardTokens Array of reward token addresses
    /// @return amounts Array of earned amounts per reward token
    function earned(
        BinPosition calldata position,
        address user,
        address[] calldata rewardTokens
    ) external view returns (uint256[] memory amounts);

    /// @notice Checks if an account has any staked position
    /// @param position The bin position details
    /// @param user The account to check
    /// @return True if the account has staked tokens
    function isStaked(
        BinPosition calldata position,
        address user
    ) external view returns (bool);
}
