// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { PoolId } from "contracts/interfaces/external/uniswap/v4/types/PoolId.sol";

/// @notice Position info returned by getPosition
struct CLPositionInfo {
    uint128 liquidity;
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
}

/// @notice Per-tick info returned by getPoolTickInfo
struct CLTickInfo {
    uint128 liquidityGross;
    int128 liquidityNet;
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
}

/// @title ICLPoolManager
/// @notice Interface for PancakeSwap Infinity CLPoolManager state reading
interface ICLPoolManager {
    /// @notice Get the current price and tick of a pool
    /// @param id The pool ID
    /// @return sqrtPriceX96 The current sqrt price
    /// @return tick The current tick
    /// @return protocolFee The protocol fee
    /// @return lpFee The LP fee
    function getSlot0(PoolId id)
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint24 protocolFee,
            uint24 lpFee
        );

    /// @notice Get the liquidity of a pool
    /// @param id The pool ID
    /// @return liquidity The pool liquidity
    function getLiquidity(PoolId id) external view returns (uint128 liquidity);

    /// @notice Get the fee growth globals of a pool
    /// @param id The pool ID
    /// @return feeGrowthGlobal0X128 The fee growth for token0
    /// @return feeGrowthGlobal1X128 The fee growth for token1
    function getFeeGrowthGlobals(PoolId id)
        external
        view
        returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128);

    /// @notice Get per-tick state for a pool
    /// @dev PancakeSwap Infinity CLPoolManager does not expose getFeeGrowthInside
    /// directly, so callers must read both tick infos and compute fee growth
    /// inside manually using the pool's current tick and fee growth globals.
    /// @param id The pool ID
    /// @param tick The tick to read
    /// @return tickInfo The tick's gross/net liquidity and feeGrowthOutside
    function getPoolTickInfo(PoolId id, int24 tick)
        external
        view
        returns (CLTickInfo memory tickInfo);

    /// @notice Get position info including fee growth
    /// @param id The pool ID
    /// @param owner The position owner
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @param salt The position salt (tokenId for position manager)
    /// @return position The position info with liquidity and fee growth
    function getPosition(
        PoolId id,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (CLPositionInfo memory position);
}
