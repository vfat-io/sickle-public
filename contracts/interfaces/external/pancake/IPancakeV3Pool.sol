// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Pool state that can change
/// @notice These methods compose the pool's state, and can change with any
/// frequency including multiple times

interface IPancakeV3Pool {
    /// @notice The 0th storage slot in the pool stores many values, and is
    /// exposed
    /// as a single method to save gas
    /// when accessed externally.
    /// @return sqrtPriceX96 The current price of the pool as a
    /// sqrt(token1/token0)
    /// Q64.96 value
    /// tick The current tick of the pool, i.e. according to the last tick
    /// transition that was run.
    /// This value may not always be equal to
    /// SqrtTickMath.getTickAtSqrtRatio(sqrtPriceX96) if the price is on a tick
    /// boundary.
    /// observationIndex The index of the last oracle observation that was
    /// written,
    /// observationCardinality The current maximum number of observations stored
    /// in
    /// the pool,
    /// observationCardinalityNext The next maximum number of observations, to
    /// be
    /// updated when the observation.
    /// feeProtocol The protocol fee for both tokens of the pool.
    /// Encoded as two 4 bit values, where the protocol fee of token1 is shifted
    /// 4
    /// bits and the protocol fee of token0
    /// is the lower 4 bits. Used as the denominator of a fraction of the swap
    /// fee,
    /// e.g. 4 means 1/4th of the swap fee.
    /// unlocked Whether the pool is currently locked to reentrancy
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    function tickSpacing() external view returns (int24);

    function liquidity() external view returns (uint128);

    function feeGrowthGlobal0X128() external view returns (uint256);

    function feeGrowthGlobal1X128() external view returns (uint256);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function fee() external view returns (uint24);
}
