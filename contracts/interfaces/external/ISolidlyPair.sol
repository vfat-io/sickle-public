// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Minimal Solidly / Uniswap-V2 style pair surface used by
/// `SolidlyPoolAdapter` for pool-direct swaps.
/// @dev `getReserves` is declared with `uint256` members so the same
/// interface decodes both the Solidly family (`uint256,uint256,uint256`)
/// and classic Uniswap V2 (`uint112,uint112,uint32`) — ABI encoding pads
/// every one of those to a 32-byte word.
interface ISolidlyPair {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function stable() external view returns (bool);

    function getReserves()
        external
        view
        returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);

    /// @notice Pair-side quote covering both the volatile (`x*y=k`) and the
    /// stable (`x³y+xy³=k`) curve, with the pair's own fee already deducted.
    /// This is the authoritative quote source — never re-derive the curve
    /// off the reserves.
    function getAmountOut(
        uint256 amountIn,
        address tokenIn
    ) external view returns (uint256 amountOut);

    /// @notice Optimistic transfer-then-settle swap. The input must already
    /// be sitting in the pair: there is no payment callback.
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
}
