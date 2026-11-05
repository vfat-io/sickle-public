// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import {
    ISwapRouter as IUniV3SwapRouter
} from "contracts/interfaces/external/uniswap/ISwapRouter.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";

/// @title UniswapV3RouterAdapter
/// @notice Per-DEX adapter for `DexType.UniswapV3Router` (original
/// SwapRouter ABI: deadline in the struct). Used on chains like Monad
/// that don't ship SwapRouter02. dexData encodes `uint24 fee`.
contract UniswapV3RouterAdapter is DexAdapterBase {
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
    ) internal override returns (uint256) {
        uint24 fee = abi.decode(step.dexData, (uint24));

        bytes memory data = abi.encodeWithSelector(
            IUniV3SwapRouter.exactInputSingle.selector,
            step.tokenIn,
            step.tokenOut,
            fee,
            msg.sender,
            block.timestamp,
            amountIn,
            0,
            0
        );

        _swapViaRouter(step.tokenIn, amountIn, step.router, data);
        return 0;
    }
}
