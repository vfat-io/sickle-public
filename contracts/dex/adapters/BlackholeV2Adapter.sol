// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import {
    IBlackholeRouter
} from "contracts/interfaces/external/blackhole/IRouter.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";

/// @title BlackholeV2Adapter
/// @notice Per-DEX adapter for `DexType.BlackholeV2Router` (Avalanche).
/// Uses Blackhole's extended `Route(pair, from, to, stable, concentrated,
/// receiver)` struct. dexData encodes `(address pair, bool stable)`.
contract BlackholeV2Adapter is DexAdapterBase {
    /// @dev Local copy of the Blackhole route struct (same layout used
    /// by `SwapRouter`). Keeping it local avoids a circular type
    /// dependency on the router for the struct alone.
    struct BlackholeRoute {
        address pair;
        address from;
        address to;
        bool stable;
        bool concentrated;
        address receiver;
    }

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
        (address pair, bool stable) = abi.decode(step.dexData, (address, bool));

        BlackholeRoute[] memory routes = new BlackholeRoute[](1);
        routes[0] = BlackholeRoute({
            pair: pair,
            from: step.tokenIn,
            to: step.tokenOut,
            stable: stable,
            concentrated: false,
            receiver: msg.sender
        });

        bytes memory data = abi.encodeWithSelector(
            IBlackholeRouter.swapExactTokensForTokens.selector,
            amountIn,
            0,
            routes,
            msg.sender,
            block.timestamp
        );

        _swapViaRouter(step.tokenIn, amountIn, step.router, data);
        return 0;
    }
}
