// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SwapParams } from "contracts/structs/SwapStructs.sol";

import {
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/structs/LiquidityStructs.sol";

struct ZapIn {
    SwapParams[] swaps;
    AddLiquidityParams addLiquidityParams;
}

struct ZapOut {
    RemoveLiquidityParams removeLiquidityParams;
    SwapParams[] swaps;
}
