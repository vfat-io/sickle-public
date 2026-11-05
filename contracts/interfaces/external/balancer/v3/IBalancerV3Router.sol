// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Liquidity subset of the Balancer V3 (Permit2) `Router`. Token
/// inputs are pulled from `msg.sender` through Permit2; BPT inputs are
/// burned from `msg.sender` against its BPT allowance to the router; outputs
/// are sent to `msg.sender`.
/// @dev Pinned against the Bush `Router` on Robinhood 4663,
/// 0xa93179c0cd90B9D1569Cf20FD403a9A67540Ea4d (`20260801-v3-router`).
interface IBalancerV3Router {
    function getVault() external view returns (address);

    function getPermit2() external view returns (address);

    function addLiquidityProportional(
        address pool,
        uint256[] memory maxAmountsIn,
        uint256 exactBptAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256[] memory amountsIn);

    function addLiquidityUnbalanced(
        address pool,
        uint256[] memory exactAmountsIn,
        uint256 minBptAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256 bptAmountOut);

    function removeLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256[] memory amountsOut);

    function removeLiquiditySingleTokenExactIn(
        address pool,
        uint256 exactBptAmountIn,
        address tokenOut,
        uint256 minAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256 amountOut);

    function queryAddLiquidityUnbalanced(
        address pool,
        uint256[] memory exactAmountsIn,
        address sender,
        bytes memory userData
    ) external returns (uint256 bptAmountOut);

    function queryRemoveLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        address sender,
        bytes memory userData
    ) external returns (uint256[] memory amountsOut);

    function queryRemoveLiquiditySingleTokenExactIn(
        address pool,
        uint256 exactBptAmountIn,
        address tokenOut,
        address sender,
        bytes memory userData
    ) external returns (uint256 amountOut);
}
