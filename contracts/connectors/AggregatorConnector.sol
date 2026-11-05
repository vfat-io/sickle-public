// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ISwapConnector, SwapParams
} from "contracts/interfaces/ISwapConnector.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct AggregatorExtraData {
    bytes data;
}

contract AggregatorConnector is ISwapConnector {
    error AggregatorSwapFailed(bytes error);
    error NotImplemented();
    error InvalidInputValue();
    error InsufficientOutputAmount(uint256 received, uint256 minRequired);
    error InvalidOutputToken();

    event SwapExecuted(
        address indexed router,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 desiredAmountOut,
        uint256 minAmountOut,
        uint256 actualAmountOut
    );

    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external override {
        if (swap.tokenIn == swap.tokenOut) {
            revert InvalidOutputToken();
        }

        AggregatorExtraData memory extraData =
            abi.decode(swap.extraData, (AggregatorExtraData));

        // For swaps to ETH, tokenOut is address(0)
        bool isETHOut = swap.tokenOut == address(0);

        uint256 balanceBefore = isETHOut
            ? address(this).balance
            : IERC20(swap.tokenOut).balanceOf(address(this));

        (bool success, bytes memory error) = swap.router.call(extraData.data);
        if (!success) {
            revert AggregatorSwapFailed(error);
        }

        uint256 balanceAfter = isETHOut
            ? address(this).balance
            : IERC20(swap.tokenOut).balanceOf(address(this));

        uint256 amountReceived = balanceAfter - balanceBefore;

        if (amountReceived < swap.minAmountOut) {
            revert InsufficientOutputAmount(amountReceived, swap.minAmountOut);
        }

        emit SwapExecuted(
            swap.router,
            swap.tokenIn,
            swap.tokenOut,
            swap.amountIn,
            swap.desiredAmountOut,
            swap.minAmountOut,
            amountReceived
        );
    }

    function swapExactETHForTokens(
        SwapParams memory swap
    ) external override {
        AggregatorExtraData memory extraData =
            abi.decode(swap.extraData, (AggregatorExtraData));

        // For ETH to token swaps, tokenOut should be a valid token
        if (swap.tokenOut == address(0)) {
            revert InvalidOutputToken();
        }

        uint256 balanceBefore = IERC20(swap.tokenOut).balanceOf(address(this));

        (bool success, bytes memory error) =
            swap.router.call{ value: swap.amountIn }(extraData.data);
        if (!success) {
            revert AggregatorSwapFailed(error);
        }

        uint256 balanceAfter = IERC20(swap.tokenOut).balanceOf(address(this));
        uint256 amountReceived = balanceAfter - balanceBefore;

        if (amountReceived < swap.minAmountOut) {
            revert InsufficientOutputAmount(amountReceived, swap.minAmountOut);
        }

        emit SwapExecuted(
            swap.router,
            swap.tokenIn,
            swap.tokenOut,
            swap.amountIn,
            swap.desiredAmountOut,
            swap.minAmountOut,
            amountReceived
        );
    }
}
