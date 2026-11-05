// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Mento v3 Router (mento-core contracts/swap/router/Router.sol).
/// Liquidity calls resolve the pool through `defaultFactory`.
interface IMentoRouter {
    function defaultFactory() external view returns (address);

    function poolFor(
        address tokenA,
        address tokenB,
        address factory
    ) external view returns (address pool);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}
