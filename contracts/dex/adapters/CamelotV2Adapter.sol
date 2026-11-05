// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import {
    ICamelotV2Router
} from "contracts/interfaces/external/camelot/ICamelotInterfaces.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";

/// @title CamelotV2Adapter
/// @notice Per-DEX adapter for `DexType.CamelotV2Router`. Camelot V2's
/// router uses `swapExactTokensForTokensSupportingFeeOnTransferTokens`
/// with an optional referrer; `dexData` encodes the referrer (or empty
/// for none).
contract CamelotV2Adapter is DexAdapterBase {
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
        address[] memory path = new address[](2);
        path[0] = step.tokenIn;
        path[1] = step.tokenOut;

        address referrer = step.dexData.length >= 32
            ? abi.decode(step.dexData, (address))
            : address(0);

        bytes memory data = abi.encodeCall(
            ICamelotV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens,
            (amountIn, 0, path, msg.sender, referrer, block.timestamp)
        );

        _swapViaRouter(step.tokenIn, amountIn, step.router, data);
        return 0;
    }
}
