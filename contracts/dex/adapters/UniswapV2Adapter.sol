// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import {
    IUniswapV2Router01
} from "contracts/interfaces/external/uniswap/IUniswapV2Router02.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";

/// @title UniswapV2Adapter
/// @notice Per-DEX adapter for `DexType.UniswapV2`. Pulls input from
/// `SwapRouter`, approves the V2 router, executes `swapExactTokensForTokens`
/// with `msg.sender` as the recipient, then revokes the approval.
contract UniswapV2Adapter is DexAdapterBase {
    constructor(
        address admin_,
        address allowlist_
    ) DexAdapterBase(admin_, allowlist_) { }

    function version() external pure override returns (uint16) {
        return 1;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = step.tokenIn;
        path[1] = step.tokenOut;

        bytes memory data = abi.encodeCall(
            IUniswapV2Router01.swapExactTokensForTokens,
            (amountIn, 0, path, msg.sender, block.timestamp)
        );

        _swapViaRouter(step.tokenIn, amountIn, step.router, data);
        return 0;
    }
}
