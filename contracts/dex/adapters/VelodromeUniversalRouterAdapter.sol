// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapStep } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IUniversalRouter
} from "contracts/interfaces/external/uniswap/v4/IUniversalRouter.sol";

/// @title VelodromeUniversalRouterAdapter
/// @notice Per-DEX adapter for `DexType.VelodromeUniversalRouter`.
/// Supports both V2 and CL (Slipstream) pools. dexData encodes
/// `(bool isCL, int24 poolParam)`. The router is pre-funded with the
/// input tokens via `adapterPull` (the V2/V3 universal-router commands
/// run with `payerIsUser = false`) and any unconsumed input is recovered
/// via a trailing SWEEP command sending the remainder back to
/// `SwapRouter`.
contract VelodromeUniversalRouterAdapter is DexAdapterBase {
    uint8 internal constant V3_SWAP_EXACT_IN = 0x00;
    uint8 internal constant V2_SWAP_EXACT_IN = 0x08;
    uint8 internal constant SWEEP = 0x04;

    error ResidualInputReturned();

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
        (bool isCL, int24 poolParam) = abi.decode(step.dexData, (bool, int24));

        bytes memory path;
        uint8 command;
        if (isCL) {
            command = V3_SWAP_EXACT_IN;
            path = abi.encodePacked(step.tokenIn, poolParam, step.tokenOut);
        } else {
            command = V2_SWAP_EXACT_IN;
            path = abi.encodePacked(
                step.tokenIn,
                poolParam == 1 ? bytes1(0x01) : bytes1(0x00),
                step.tokenOut
            );
        }

        bytes memory commands = abi.encodePacked(command, SWEEP);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            msg.sender, // output recipient
            amountIn,
            uint256(0),
            path,
            false, // payerIsUser = false (tokens already in router)
            false // isUni = false (use Velodrome/Aerodrome factory)
        );
        inputs[1] = abi.encode(step.tokenIn, msg.sender, uint256(0));

        _adapterPullTo(step.tokenIn, amountIn, step.router);
        uint256 inputBalanceAfterPull =
            IERC20(step.tokenIn).balanceOf(msg.sender);
        _adapterCall(
            step.router,
            0,
            abi.encodeCall(
                IUniversalRouter.execute, (commands, inputs, block.timestamp)
            )
        );
        if (IERC20(step.tokenIn).balanceOf(msg.sender) > inputBalanceAfterPull)
        {
            revert ResidualInputReturned();
        }
        return 0;
    }
}
