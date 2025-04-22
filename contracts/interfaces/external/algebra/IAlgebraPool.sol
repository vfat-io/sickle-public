// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.4;

/// @title The interface for a Algebra Pool
/// @dev The pool interface is broken up into many smaller pieces.
/// This interface includes custom error definitions and cannot be used in older
/// versions of Solidity.
/// For older versions of Solidity use #IAlgebraPoolLegacy
/// Credit to Uniswap Labs under GPL-2.0-or-later license:
/// https://github.com/Uniswap/v3-core/tree/main/contracts/interfaces
interface IAlgebraPool {
    /// @notice The globalState structure in the pool stores many values but
    /// requires only one slot
    /// and is exposed as a single method to save gas when accessed externally.
    /// @dev **important security note: caller should check `unlocked` flag to
    /// prevent read-only reentrancy**
    /// @return price The current price of the pool as a sqrt(dToken1/dToken0)
    /// Q64.96 value
    /// @return tick The current tick of the pool, i.e. according to the last
    /// tick transition that was run
    /// This value may not always be equal to
    /// SqrtTickMath.getTickAtSqrtRatio(price) if the price is on a tick
    /// boundary
    /// @return lastFee The current (last known) pool fee value in hundredths of
    /// a bip, i.e. 1e-6 (so '100' is '0.01%'). May be obsolete if using dynamic
    /// fee plugin
    /// @return pluginConfig The current plugin config as bitmap. Each bit is
    /// responsible for enabling/disabling the hooks, the last bit turns on/off
    /// dynamic fees logic
    /// @return communityFee The community fee represented as a percent of all
    /// collected fee in thousandths, i.e. 1e-3 (so 100 is 10%)
    /// @return unlocked Reentrancy lock flag, true if the pool currently is
    /// unlocked, otherwise - false
    function globalState()
        external
        view
        returns (
            uint160 price,
            int24 tick,
            uint16 lastFee,
            uint8 pluginConfig,
            uint16 communityFee,
            bool unlocked
        );

    /// @notice Look up information about a specific tick in the pool
    /// @dev **important security note: caller should check reentrancy lock to
    /// prevent read-only reentrancy**
    /// @param tick The tick to look up
    /// @return liquidityTotal The total amount of position liquidity that uses
    /// the pool either as tick lower or tick upper
    /// @return liquidityDelta How much liquidity changes when the pool price
    /// crosses the tick
    /// @return prevTick The previous tick in tick list
    /// @return nextTick The next tick in tick list
    /// @return outerFeeGrowth0Token The fee growth on the other side of the
    /// tick from the current tick in token0
    /// @return outerFeeGrowth1Token The fee growth on the other side of the
    /// tick from the current tick in token1
    /// In addition, these values are only relative and must be used only in
    /// comparison to previous snapshots for
    /// a specific position.
    function ticks(
        int24 tick
    )
        external
        view
        returns (
            uint256 liquidityTotal,
            int128 liquidityDelta,
            int24 prevTick,
            int24 nextTick,
            uint256 outerFeeGrowth0Token,
            uint256 outerFeeGrowth1Token
        );

    /// @notice The fee growth as a Q128.128 fees of token0 collected per unit
    /// of liquidity for the entire life of the pool
    /// @dev This value can overflow the uint256
    /// @return The fee growth accumulator for token0
    function totalFeeGrowth0Token() external view returns (uint256);

    /// @notice The fee growth as a Q128.128 fees of token1 collected per unit
    /// of liquidity for the entire life of the pool
    /// @dev This value can overflow the uint256
    /// @return The fee growth accumulator for token1
    function totalFeeGrowth1Token() external view returns (uint256);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function tickSpacing() external view returns (int24);

    function liquidity() external view returns (uint128);
}
