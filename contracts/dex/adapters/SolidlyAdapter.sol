// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import {
    ISolidlyRouter
} from "contracts/interfaces/external/ISolidlyRouter.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";

/// @title SolidlyAdapter
/// @notice Per-DEX adapter for `DexType.Solidly` — Thena, Ramses, Pharaoh,
/// Shadow, Equalizer, and other legacy Solidly forks. dexData encodes
/// `(bool stable)`.
contract SolidlyAdapter is DexAdapterBase {
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
        bool stable = abi.decode(step.dexData, (bool));
        ISolidlyRouter.Route[] memory routes = new ISolidlyRouter.Route[](1);
        routes[0] = ISolidlyRouter.Route({
            from: step.tokenIn, to: step.tokenOut, stable: stable
        });

        bytes memory data = abi.encodeWithSelector(
            ISolidlyRouter.swapExactTokensForTokens.selector,
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
