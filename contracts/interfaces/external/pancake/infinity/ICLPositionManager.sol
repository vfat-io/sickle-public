// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { PancakePoolKey } from "./PancakePoolKey.sol";
import { ICLPoolManager } from "./ICLPoolManager.sol";
import {
    PositionInfo
} from "contracts/interfaces/external/uniswap/v4/libraries/PositionInfoLibrary.sol";

/// @title ICLPositionManager
/// @notice Interface for PancakeSwap Infinity CLPositionManager
interface ICLPositionManager {
    /// @notice Unlocks the pool manager and batches actions for modifying liquidity
    /// @param unlockData Encoding of actions and parameters
    /// @param deadline The deadline for the batched actions
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external payable;

    /// @notice Batches actions without unlocking (must be called when already unlocked)
    /// @param actions The actions to perform
    /// @param params The parameters for the actions
    function modifyLiquiditiesWithoutUnlock(
        bytes calldata actions,
        bytes[] calldata params
    ) external payable;

    /// @notice Get the next token ID that will be minted
    function nextTokenId() external view returns (uint256);

    /// @notice Get the liquidity of a position
    /// @param tokenId The ERC721 token ID
    function getPositionLiquidity(
        uint256 tokenId
    ) external view returns (uint128 liquidity);

    /// @notice Get pool key and position info for a token
    /// @param tokenId The ERC721 token ID
    /// @return poolKey The PancakeSwap Infinity pool key
    /// @return info The position info (packed tickLower, tickUpper, etc.)
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (PancakePoolKey memory poolKey, PositionInfo info);

    /// @notice Get position info for a token
    /// @param tokenId The ERC721 token ID
    function positionInfo(
        uint256 tokenId
    ) external view returns (PositionInfo);

    /// @notice Get the owner of a token
    /// @param tokenId The ERC721 token ID
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Get the pool manager
    function poolManager() external view returns (ICLPoolManager);

    /// @notice Get the pool key for a pool ID
    /// @param poolId The 25-byte pool ID
    /// @return The pool key
    function poolKeys(
        bytes25 poolId
    ) external view returns (PancakePoolKey memory);
}
