// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import {
    ISlipstreamSwapRouter
} from "contracts/interfaces/external/aerodrome/ISlipstreamSwapRouter.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";

/// @title SlipstreamRouterAdapter
/// @notice Per-DEX adapter for `DexType.SlipstreamRouter` (Aerodrome's
/// concentrated-liquidity router on Base). Uses `exactInputSingle` keyed
/// by `tickSpacing` rather than fee. dexData encodes `int24 tickSpacing`.
contract SlipstreamRouterAdapter is DexAdapterBase {
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
        int24 tickSpacing = abi.decode(step.dexData, (int24));

        bytes memory data = abi.encodeWithSelector(
            ISlipstreamSwapRouter.exactInputSingle.selector,
            step.tokenIn,
            step.tokenOut,
            tickSpacing,
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
