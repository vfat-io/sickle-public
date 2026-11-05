// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Balancer V3 prepaid `AggregatorRouter`. The caller transfers the
/// input to the Vault first; the router settles that prepayment, swaps, and
/// sends the output to `msg.sender`.
/// @dev Pinned against the Bush deployment on Robinhood 4663,
/// 0x63c206f2038dF509Dad4a4c88239E7B6e4B8a38e (sourcify-verified
/// `contracts/AggregatorRouter.sol`).
interface IBalancerV3AggregatorRouter {
    error SwapInsufficientPayment();

    function getVault() external view returns (address);

    function swapSingleTokenExactIn(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 exactAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata userData
    ) external returns (uint256 amountOut);

    function querySwapSingleTokenExactIn(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 exactAmountIn,
        address sender,
        bytes calldata userData
    ) external returns (uint256 amountOut);
}
