// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { PoolKey } from "./types/PoolKey.sol";
import { PositionInfo } from "./libraries/PositionInfoLibrary.sol";
import { IPoolManager } from "./IPoolManager.sol";

interface IImmutableState {
    /// @notice The Uniswap v4 PoolManager contract
    function poolManager() external view returns (IPoolManager);
}

/// @title IPositionManager
/// @notice Interface for the PositionManager contract
interface IPositionManager is IImmutableState {
    /// @notice Thrown when the caller is not approved to modify a position
    error NotApproved(address caller);
    /// @notice Thrown when the block.timestamp exceeds the user-provided
    /// deadline
    error DeadlinePassed(uint256 deadline);
    /// @notice Thrown when calling transfer, subscribe, or unsubscribe when the
    /// PoolManager is unlocked.
    /// @dev This is to prevent hooks from being able to trigger notifications
    /// at the same time the position is being modified.
    error PoolManagerMustBeLocked();

    /// @notice Unlocks Uniswap v4 PoolManager and batches actions for modifying
    /// liquidity
    /// @dev This is the standard entrypoint for the PositionManager
    /// @param unlockData is an encoding of actions, and parameters for those
    /// actions
    /// @param deadline is the deadline for the batched actions to be executed
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external payable;

    /// @notice Batches actions for modifying liquidity without unlocking v4
    /// PoolManager
    /// @dev This must be called by a contract that has already unlocked the v4
    /// PoolManager
    /// @param actions the actions to perform
    /// @param params the parameters to provide for the actions
    function modifyLiquiditiesWithoutUnlock(
        bytes calldata actions,
        bytes[] calldata params
    ) external payable;

    /// @notice Used to get the ID that will be used for the next minted
    /// liquidity position
    /// @return uint256 The next token ID
    function nextTokenId() external view returns (uint256);

    /// @notice Returns the liquidity of a position
    /// @param tokenId the ERC721 tokenId
    /// @return liquidity the position's liquidity, as a liquidityAmount
    /// @dev this value can be processed as an amount0 and amount1 by using the
    /// LiquidityAmounts library
    function getPositionLiquidity(
        uint256 tokenId
    ) external view returns (uint128 liquidity);

    /// @notice Returns the pool key and position info of a position
    /// @param tokenId the ERC721 tokenId
    /// @return poolKey the pool key of the position
    /// @return PositionInfo a uint256 packed value holding information about
    /// the position including the range (tickLower, tickUpper)
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (PoolKey memory, PositionInfo);

    /// @notice Returns the position info of a position
    /// @param tokenId the ERC721 tokenId
    /// @return a uint256 packed value holding information about the position
    /// including the range (tickLower, tickUpper)
    function positionInfo(
        uint256 tokenId
    ) external view returns (PositionInfo);

    /// @notice Returns the pool key of a pool
    /// @param poolId the pool ID
    /// @return poolKey the pool key of the pool
    function poolKeys(
        bytes25 poolId
    ) external view returns (PoolKey memory);

    /// @notice Returns the owner of a token
    /// @param tokenId the ERC721 tokenId
    /// @return owner the owner of the token
    function ownerOf(
        uint256 tokenId
    ) external view returns (address);
}
