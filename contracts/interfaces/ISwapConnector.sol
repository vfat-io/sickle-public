// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SwapParams } from "contracts/structs/SwapStructs.sol";

interface ISwapConnector {
    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external;

    function swapExactETHForTokens(
        SwapParams memory swap
    ) external;
}
