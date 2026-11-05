// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct SwapParams {
    address tokenApproval;
    address router;
    uint256 amountIn;
    uint256 desiredAmountOut;
    uint256 minAmountOut;
    address tokenIn;
    address tokenOut;
    bytes extraData;
}
