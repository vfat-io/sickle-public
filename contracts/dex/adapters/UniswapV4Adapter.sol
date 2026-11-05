// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IAllowanceTransfer
} from "contracts/interfaces/external/IAllowanceTransfer.sol";
import {
    IUniversalRouter
} from "contracts/interfaces/external/uniswap/v4/IUniversalRouter.sol";
import {
    Actions
} from "contracts/interfaces/external/uniswap/v4/libraries/Actions.sol";
import {
    IV4Router
} from "contracts/interfaces/external/uniswap/v4/IV4Router.sol";
import {
    Permit2AllowanceLib
} from "contracts/libraries/Permit2AllowanceLib.sol";
import {
    PoolKey
} from "contracts/interfaces/external/uniswap/v4/types/PoolKey.sol";
import { IHooks } from "contracts/interfaces/external/uniswap/v4/IHooks.sol";
import {
    Currency
} from "contracts/interfaces/external/uniswap/v4/types/Currency.sol";

/// @title UniswapV4Adapter
/// @notice Per-DEX adapter for `DexType.UniswapV4`. `SwapRouter` does
/// the Permit2 dance (so the router's `transferFrom` lifts tokens
/// directly from `SwapRouter`) and is `msg.sender` for the universal
/// router call, meaning `TAKE_ALL` delivers output back into
/// `SwapRouter` without an intermediate sweep.
contract UniswapV4Adapter is DexAdapterBase {
    uint8 internal constant V4_SWAP = 0x10;

    address public constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

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
        PoolKey memory poolKey = abi.decode(step.dexData, (PoolKey));
        if (poolKey.hooks != IHooks(address(0))) {
            allowlist.requireAllowedHook(address(poolKey.hooks));
        }

        bool hasFixedPermit2Allowance;
        if (step.tokenIn != address(0)) {
            hasFixedPermit2Allowance = Permit2AllowanceLib.hasFixedAllowance(
                step.tokenIn, msg.sender, PERMIT2
            );
            if (!hasFixedPermit2Allowance) {
                _adapterApprove(step.tokenIn, PERMIT2, amountIn);
            }
            _adapterCall(
                PERMIT2,
                0,
                abi.encodeCall(
                    IAllowanceTransfer.approve,
                    (
                        step.tokenIn,
                        step.router,
                        // forge-lint: disable-next-line(unsafe-typecast)
                        uint160(amountIn),
                        uint48(block.timestamp)
                    )
                )
            );
        }

        {
            bytes memory input = _buildV4Input(step, poolKey, amountIn);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = input;

            uint256 value = step.tokenIn == address(0) ? amountIn : 0;
            _adapterCall(
                step.router,
                value,
                abi.encodeCall(
                    IUniversalRouter.execute,
                    (abi.encodePacked(V4_SWAP), inputs, block.timestamp)
                )
            );
        }

        if (step.tokenIn != address(0)) {
            if (!hasFixedPermit2Allowance) {
                _adapterApprove(step.tokenIn, PERMIT2, 0);
            }
            _adapterCall(
                PERMIT2,
                0,
                abi.encodeCall(
                    IAllowanceTransfer.approve,
                    (step.tokenIn, step.router, 0, 0)
                )
            );
        }
        return 0;
    }

    function _buildV4Input(
        SwapStep calldata step,
        PoolKey memory poolKey,
        uint256 amountIn
    ) internal pure returns (bytes memory) {
        (address currency0, address currency1) = step.tokenIn < step.tokenOut
            ? (step.tokenIn, step.tokenOut)
            : (step.tokenOut, step.tokenIn);

        bool zeroForOne = step.tokenIn == currency0;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);

        IV4Router.ExactInputSingleParams memory swapParams =
            IV4Router.ExactInputSingleParams({
                poolKey: PoolKey({
                    currency0: Currency.wrap(currency0),
                    currency1: Currency.wrap(currency1),
                    fee: poolKey.fee,
                    hooks: poolKey.hooks,
                    tickSpacing: poolKey.tickSpacing
                }),
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: new bytes(0)
            });
        params[0] = abi.encode(swapParams);
        params[1] = abi.encode(step.tokenIn, amountIn);
        params[2] = abi.encode(step.tokenOut, 0);

        return abi.encode(actions, params);
    }
}
