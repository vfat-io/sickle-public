// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    Currency
} from "contracts/interfaces/external/uniswap/v4/types/Currency.sol";
import { IHooks } from "contracts/interfaces/external/uniswap/v4/IHooks.sol";
import { ICLPoolManager } from "./ICLPoolManager.sol";

/// @notice PancakeSwap Infinity PoolKey structure
/// @dev Different from Uniswap V4 PoolKey - has poolManager and parameters fields
struct PancakePoolKey {
    /// @notice The lower currency of the pool, sorted numerically
    Currency currency0;
    /// @notice The higher currency of the pool, sorted numerically
    Currency currency1;
    /// @notice The hooks of the pool
    IHooks hooks;
    /// @notice The pool manager (CLPoolManager or BinPoolManager)
    ICLPoolManager poolManager;
    /// @notice The pool LP fee, capped at 1_000_000
    uint24 fee;
    /// @notice Parameters encoding hook permissions and tickSpacing
    /// Bits [0-16): hook permissions
    /// Bits [16-40): tickSpacing (24-bit)
    bytes32 parameters;
}

/// @notice Library for PancakePoolKey operations
library PancakePoolKeyLibrary {
    uint8 internal constant OFFSET_TICK_SPACING = 16;

    /// @notice Extract tickSpacing from parameters
    function getTickSpacing(
        PancakePoolKey memory key
    ) internal pure returns (int24) {
        return int24(uint24(uint256(key.parameters) >> OFFSET_TICK_SPACING));
    }

    /// @notice Encode tickSpacing into parameters
    function setTickSpacing(
        bytes32 parameters,
        int24 tickSpacing
    ) internal pure returns (bytes32) {
        return
            parameters | bytes32(uint256(uint24(tickSpacing)) << OFFSET_TICK_SPACING);
    }
}
