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
import { IHooks } from "contracts/interfaces/external/uniswap/v4/IHooks.sol";
import {
    Currency
} from "contracts/interfaces/external/uniswap/v4/types/Currency.sol";
import {
    PancakePoolKey
} from "contracts/interfaces/external/pancake/infinity/PancakePoolKey.sol";
import {
    Permit2AllowanceLib
} from "contracts/libraries/Permit2AllowanceLib.sol";

/// @title PancakeInfinityAdapter
/// @notice Per-DEX adapter for `DexType.PancakeInfinity`. Mirrors the
/// V4 adapter but targets the Pancake Infinity Permit2 deployment and
/// the Pancake-flavoured `PoolKey`.
contract PancakeInfinityAdapter is DexAdapterBase {
    // Pancake's UniversalRouter command shares the byte value of
    // Uniswap V4's command (0x10).
    uint8 internal constant INFI_SWAP = 0x10;

    address public constant PANCAKE_INFINITY_PERMIT2 =
        0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;

    struct ExactInputSingleParams {
        PancakePoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
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
        PancakePoolKey memory poolKey =
            abi.decode(step.dexData, (PancakePoolKey));
        if (poolKey.hooks != IHooks(address(0))) {
            allowlist.requireAllowedHook(address(poolKey.hooks));
        }

        bool hasFixedPermit2Allowance;
        if (step.tokenIn != address(0)) {
            hasFixedPermit2Allowance = Permit2AllowanceLib.hasFixedAllowance(
                step.tokenIn, msg.sender, PANCAKE_INFINITY_PERMIT2
            );
            if (!hasFixedPermit2Allowance) {
                _adapterApprove(
                    step.tokenIn, PANCAKE_INFINITY_PERMIT2, amountIn
                );
            }
            _adapterCall(
                PANCAKE_INFINITY_PERMIT2,
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
            bytes memory input = _buildInput(step, poolKey, amountIn);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = input;

            uint256 value = step.tokenIn == address(0) ? amountIn : 0;
            _adapterCall(
                step.router,
                value,
                abi.encodeCall(
                    IUniversalRouter.execute,
                    (abi.encodePacked(INFI_SWAP), inputs, block.timestamp)
                )
            );
        }

        if (step.tokenIn != address(0)) {
            if (!hasFixedPermit2Allowance) {
                _adapterApprove(step.tokenIn, PANCAKE_INFINITY_PERMIT2, 0);
            }
            _adapterCall(
                PANCAKE_INFINITY_PERMIT2,
                0,
                abi.encodeCall(
                    IAllowanceTransfer.approve,
                    (step.tokenIn, step.router, 0, 0)
                )
            );
        }
        return 0;
    }

    function _buildInput(
        SwapStep calldata step,
        PancakePoolKey memory poolKey,
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

        ExactInputSingleParams memory swapParams = ExactInputSingleParams({
            poolKey: PancakePoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                hooks: poolKey.hooks,
                poolManager: poolKey.poolManager,
                fee: poolKey.fee,
                parameters: poolKey.parameters
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
