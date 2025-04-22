// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICLPool {
    error DepositsNotEqual();
    error BelowMinimumK();
    error FactoryAlreadySet();
    error InsufficientLiquidity();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error IsPaused();
    error InvalidTo();
    error K();
    error NotEmergencyCouncil();

    event Fees(address indexed sender, uint256 amount0, uint256 amount1);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        address indexed to,
        uint256 amount0,
        uint256 amount1
    );
    event Swap(
        address indexed sender,
        address indexed to,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event Sync(uint256 reserve0, uint256 reserve1);
    event Claim(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1
    );

    // Struct to capture time period obervations every 30 minutes, used for
    // local oracles
    struct Observation {
        uint256 timestamp;
        uint256 reserve0Cumulative;
        uint256 reserve1Cumulative;
    }

    /// @notice The 0th storage slot in the pool stores many values, and is
    /// exposed as a single method to save gas
    /// when accessed externally.
    /// @return sqrtPriceX96 The current price of the pool as a
    /// sqrt(token1/token0) Q64.96 value
    /// @return tick The current tick of the pool, i.e. according to the last
    /// tick transition that was run.
    /// This value may not always be equal to
    /// SqrtTickMath.getTickAtSqrtRatio(sqrtPriceX96) if the price is on a tick
    /// boundary.
    /// @return observationIndex The index of the last oracle observation that
    /// was written,
    /// @return observationCardinality The current maximum number of
    /// observations stored in the pool,
    /// @return observationCardinalityNext The next maximum number of
    /// Encoded as two 4 bit values, where the protocol fee of token1 is shifted
    /// 4 bits and the protocol fee of token0
    /// is the lower 4 bits. Used as the denominator of a fraction of the swap
    /// fee, e.g. 4 means 1/4th of the swap fee.
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
            bool unlocked
        );

    /// @notice Returns the decimal (dec), reserves (r), stable (st), and tokens
    /// (t) of token0 and token1
    function metadata()
        external
        view
        returns (
            uint256 dec0,
            uint256 dec1,
            uint256 r0,
            uint256 r1,
            bool st,
            address t0,
            address t1
        );

    /// @notice Claim accumulated but unclaimed fees (claimable0 and claimable1)
    function claimFees() external returns (uint256, uint256);

    /// @notice Returns [token0, token1]
    function tokens() external view returns (address, address);

    /// @notice Address of token in the pool with the lower address value
    function token0() external view returns (address);

    /// @notice Address of token in the poool with the higher address value
    function token1() external view returns (address);

    /// @notice Address of linked PoolFees.sol
    function poolFees() external view returns (address);

    /// @notice Address of PoolFactory that created this contract
    function factory() external view returns (address);

    /// @notice Capture oracle reading every 30 minutes (1800 seconds)
    function periodSize() external view returns (uint256);

    /// @notice Amount of token0 in pool
    function reserve0() external view returns (uint256);

    /// @notice Amount of token1 in pool
    function reserve1() external view returns (uint256);

    /// @notice Timestamp of last update to pool
    function blockTimestampLast() external view returns (uint256);

    /// @notice Cumulative of reserve0 factoring in time elapsed
    function reserve0CumulativeLast() external view returns (uint256);

    /// @notice Cumulative of reserve1 factoring in time elapsed
    function reserve1CumulativeLast() external view returns (uint256);

    /// @notice Accumulated fees of token0 (global)
    function index0() external view returns (uint256);

    /// @notice Accumulated fees of token1 (global)
    function index1() external view returns (uint256);

    /// @notice Get an LP's relative index0 to index0
    function supplyIndex0(
        address
    ) external view returns (uint256);

    /// @notice Get an LP's relative index1 to index1
    function supplyIndex1(
        address
    ) external view returns (uint256);

    /// @notice Amount of unclaimed, but claimable tokens from fees of token0
    /// for an LP
    function claimable0(
        address
    ) external view returns (uint256);

    /// @notice Amount of unclaimed, but claimable tokens from fees of token1
    /// for an LP
    function claimable1(
        address
    ) external view returns (uint256);

    /// @notice Returns the value of K in the Pool, based on its reserves.
    function getK() external returns (uint256);

    /// @notice Set pool name
    ///         Only callable by Voter.emergencyCouncil()
    /// @param __name String of new name
    function setName(
        string calldata __name
    ) external;

    /// @notice Set pool symbol
    ///         Only callable by Voter.emergencyCouncil()
    /// @param __symbol String of new symbol
    function setSymbol(
        string calldata __symbol
    ) external;

    /// @notice Get the number of observations recorded
    function observationLength() external view returns (uint256);

    /// @notice Get the value of the most recent observation
    function lastObservation() external view returns (Observation memory);

    /// @notice True if pool is stable, false if volatile
    function stable() external view returns (bool);

    /// @notice Produces the cumulative price using counterfactuals to save gas
    /// and avoid a call to sync.
    function currentCumulativePrices()
        external
        view
        returns (
            uint256 reserve0Cumulative,
            uint256 reserve1Cumulative,
            uint256 blockTimestamp
        );

    /// @notice Provides twap price with user configured granularity, up to the
    /// full window size
    /// @param tokenIn .
    /// @param amountIn .
    /// @param granularity .
    /// @return amountOut .
    function quote(
        address tokenIn,
        uint256 amountIn,
        uint256 granularity
    ) external view returns (uint256 amountOut);

    /// @notice Returns a memory set of TWAP prices
    ///         Same as calling sample(tokenIn, amountIn, points, 1)
    /// @param tokenIn .
    /// @param amountIn .
    /// @param points Number of points to return
    /// @return Array of TWAP prices
    function prices(
        address tokenIn,
        uint256 amountIn,
        uint256 points
    ) external view returns (uint256[] memory);

    /// @notice Same as prices with with an additional window argument.
    ///         Window = 2 means 2 * 30min (or 1 hr) between observations
    /// @param tokenIn .
    /// @param amountIn .
    /// @param points .
    /// @param window .
    /// @return Array of TWAP prices
    function sample(
        address tokenIn,
        uint256 amountIn,
        uint256 points,
        uint256 window
    ) external view returns (uint256[] memory);

    /// @notice This low-level function should be called from a contract which
    /// performs important safety checks
    /// @param amount0Out   Amount of token0 to send to `to`
    /// @param amount1Out   Amount of token1 to send to `to`
    /// @param to           Address to recieve the swapped output
    /// @param data         Additional calldata for flashloans
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /// @notice This low-level function should be called from a contract which
    /// performs important safety checks
    ///         standard uniswap v2 implementation
    /// @param to Address to receive token0 and token1 from burning the pool
    /// token
    /// @return amount0 Amount of token0 returned
    /// @return amount1 Amount of token1 returned
    function burn(
        address to
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice This low-level function should be called by addLiquidity
    /// functions in Router.sol, which performs important safety checks
    ///         standard uniswap v2 implementation
    /// @param to           Address to receive the minted LP token
    /// @return liquidity   Amount of LP token minted
    function mint(
        address to
    ) external returns (uint256 liquidity);

    /// @notice Update reserves and, on the first call per block, price
    /// accumulators
    /// @return _reserve0 .
    /// @return _reserve1 .
    /// @return _blockTimestampLast .
    function getReserves()
        external
        view
        returns (
            uint256 _reserve0,
            uint256 _reserve1,
            uint256 _blockTimestampLast
        );

    /// @notice Get the amount of tokenOut given the amount of tokenIn
    /// @param amountIn Amount of token in
    /// @param tokenIn  Address of token
    /// @return Amount out
    function getAmountOut(
        uint256 amountIn,
        address tokenIn
    ) external view returns (uint256);

    /// @notice Force balances to match reserves
    /// @param to Address to receive any skimmed rewards
    function skim(
        address to
    ) external;

    /// @notice Force reserves to match balances
    function sync() external;

    /// @notice Called on pool creation by PoolFactory
    /// @param _token0 Address of token0
    /// @param _token1 Address of token1
    /// @param _stable True if stable, false if volatile
    function initialize(
        address _token0,
        address _token1,
        bool _stable
    ) external;

    /// @notice Look up information about a specific tick in the pool
    /// @param tick The tick to look up
    /// @return liquidityGross the total amount of position liquidity that uses
    /// the pool either as tick lower or
    /// tick upper,
    /// liquidityNet how much liquidity changes when the pool price crosses the
    /// tick,
    /// stakedLiquidityNet how much staked liquidity changes when the pool price
    /// crosses the tick,
    /// feeGrowthOutside0X128 the fee growth on the other side of the tick from
    /// the current tick in token0,
    /// feeGrowthOutside1X128 the fee growth on the other side of the tick from
    /// the current tick in token1,
    /// rewardGrowthOutsideX128 the reward growth on the other side of the tick
    /// from the current tick in emission token
    /// tickCumulativeOutside the cumulative tick value on the other side of the
    /// tick from the current tick
    /// secondsPerLiquidityOutsideX128 the seconds spent per liquidity on the
    /// other side of the tick from the current tick,
    /// secondsOutside the seconds spent on the other side of the tick from the
    /// current tick,
    /// initialized Set to true if the tick is initialized, i.e. liquidityGross
    /// is greater than 0, otherwise equal to false.
    /// Outside values can only be used if the tick is initialized, i.e. if
    /// liquidityGross is greater than 0.
    /// In addition, these values are only relative and must be used only in
    /// comparison to previous snapshots for
    /// a specific position.
    function ticks(
        int24 tick
    )
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            int128 stakedLiquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            uint256 rewardGrowthOutsideX128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function fee() external view returns (uint24);

    function tickSpacing() external view returns (int24);

    function liquidity() external view returns (uint128);

    function feeGrowthGlobal0X128() external view returns (uint256);

    function feeGrowthGlobal1X128() external view returns (uint256);
}
