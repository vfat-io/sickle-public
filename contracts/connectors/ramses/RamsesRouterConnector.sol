// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IRamsesRouter } from
    "contracts/interfaces/external/ramses/IRamsesRouter.sol";

import {
    VelodromeRouterConnector,
    SwapParams
} from "contracts/connectors/velodrome/VelodromeRouterConnector.sol";

struct RamsesSwapExtraData {
    IRamsesRouter.Route[] routes;
}

contract RamsesRouterConnector is VelodromeRouterConnector {
    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external payable override {
        RamsesSwapExtraData memory _extraData =
            abi.decode(swap.extraData, (RamsesSwapExtraData));
        IRamsesRouter(swap.router).swapExactTokensForTokens(
            swap.amountIn,
            swap.minAmountOut,
            _extraData.routes,
            address(this),
            block.timestamp
        );
    }
}
